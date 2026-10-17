# shellcheck shell=bash disable=SC2154
# managers.sh: the managers (github, gitlab, jsonfeed, static, dirlist,
# dateprobe) and the up-to-date test. Loaded by load.sh.
# SC2154: cfg keys and per-item variables are assigned outside this file.

# ---------------------------------------------------------------------------
# GitHub / GitLab asset helpers
# ---------------------------------------------------------------------------
# A shell glob as an anchored regex: * and ? are wildcards, [...] stays a
# character class, and every other regex character matches literally.
glob_to_regex() {
    local p="$1" out="" ch i
    for (( i = 0; i < ${#p}; i++ )); do
        ch="${p:i:1}"
        case "$ch" in
            '*') out+='.*' ;;
            '?') out+='.' ;;
            '.'|"\\"|'^'|'$'|'+'|'('|')'|'{'|'}'|'|') out+="\\$ch" ;;
            *)   out+="$ch" ;;
        esac
    done
    printf '^%s$' "$out"
}

# Sets asset_pat, the anchored regex an asset's name must match: repo_regex as
# written (for what a glob can't say, like SoH-.*(\.appimage|-Linux\.zip)), or
# the repo_filename glob converted. $1 = the manager, for the messages. Returns
# 1, having said why, unless exactly one of them is set and the regex compiles.
asset_regex() {
    if [[ -n "${repo_regex:-}" && -n "${repo_filename:-}" ]]; then
        say "⚠ ${PROGRESS_LABEL:-}: set repo_filename or repo_regex, not both, skipping"
        return 1
    elif [[ -n "${repo_regex:-}" ]]; then
        asset_pat="^(?:$repo_regex)\$"
        # jq fails on a regex it can't compile, before any request is made
        if ! jq -n --arg r "$asset_pat" '"" | test($r)' >/dev/null 2>&1; then
            say "⚠ ${PROGRESS_LABEL:-}: repo_regex '$repo_regex' isn't a valid regex, skipping"
            return 1
        fi
    elif [[ -n "${repo_filename:-}" ]]; then
        asset_pat=$(glob_to_regex "$repo_filename")
    else
        say "⚠ ${PROGRESS_LABEL:-}: $1 manager needs repo_filename or repo_regex, skipping"
        return 1
    fi
    debug "asset pattern: $asset_pat"
}

# Print "<tag>\t<url>\t<digest>" for the newest suitable release that has a
# matching asset. <digest> is GitHub's sha256, or "updated:<time>" for older
# assets without one. $3 = true|false → whether pre-releases are eligible.
pick_github_asset() {
    local json="$1" regex="$2" include_pre="$3"
    jq -r --arg pat "$regex" --argjson pre "$include_pre" '
        if type != "array" then empty else
            [ .[]
              | select((.draft // false) | not)
              | select($pre or ((.prerelease // false) | not))
              | . as $r
              | ([ $r.assets[] | select(.name | test($pat)) ][0]) as $a
              | select($a != null)
              | [$r.tag_name, $a.browser_download_url, ($a.digest // ($a.updated_at | if . then "updated:" + . else "" end))] ]
            | (.[0] // empty) | @tsv
        end' <<<"$json" 2>/dev/null
}

pick_gitlab_asset() {
    local json="$1" regex="$2"
    jq -r --arg pat "$regex" '
        if type != "array" then empty else
            [ .[]
              | . as $r
              | ([ ($r.assets.links // [])[] | select(.name | test($pat)) ][0]) as $a
              | select($a != null)
              | [$r.tag_name, ($a.direct_asset_url // $a.url), $a.name] ]
            | (.[0] // empty) | @tsv
        end' <<<"$json" 2>/dev/null
}

# ---------------------------------------------------------------------------
# dirlist manager: globs in a URL, resolved against the server's listings
# ---------------------------------------------------------------------------
# Names in a server's directory listing, folders with a trailing "/". Copes with
# plain index pages and SourceForge (absolute links ending in "/download").
# Returns 1 when the folder isn't there (404, 410: a definite answer, so the
# next candidate may be tried; SourceForge lists links like "Docs Home/" that
# 404), and 2 when the server gave no answer (timeout, connection error, other
# HTTP errors).
list_dir() {
    local page code
    page=$(curl -sL "${CURL_META[@]}" -w '\n%{http_code}' "$1") || return 2
    code="${page##*$'\n'}"; page="${page%$'\n'*}"
    case "$code" in
        2??)     ;;
        404|410) return 1 ;;
        *)       return 2 ;;
    esac
    grep -oE 'href="[^"]+"' <<<"$page" | awk '
        { h = substr($0, 7, length($0) - 7); sub(/[?#].*/, "", h); sub(/\/download$/, "", h)
          dir = (h ~ /\/$/); sub(/\/$/, "", h); n = split(h, p, "/"); name = p[n]
          if (name != "" && name != "." && name != "..") print name (dir ? "/" : "") }' | sort -u
    return 0
}

# The stdin entries matching glob $1, newest first, judged by the numbers in the
# part the wildcards matched: EndeavourOS_Titan-Nova-2026.08.15 must beat
# Ganymede-Neo-2026.01.12, and the fixed "amd64" in a name must not count.
# Entries without any number there come last; URL escapes don't count as numbers
# (the 20 in SourceForge's "Docs%20Home/").
sort_newest() {
    local glob="$1" entry head tail
    head="${glob%%[\[*?]*}"; tail="${glob##*\*}"
    while IFS= read -r entry; do
        # shellcheck disable=SC2053
        [[ "$entry" == $glob ]] && printf '%s\n' "$entry"
    done | awk -v h="${#head}" -v t="${#tail}" '
        { k = substr($0, h + 1, length($0) - h - t); gsub(/%[0-9A-Fa-f][0-9A-Fa-f]/, " ", k)
          gsub(/[^0-9]+/, ".", k); gsub(/^\.|\.$/, "", k)
          print (k == "" ? 0 : 1) "\t" k "\t" $0 }' | sort -t $'\t' -k1,1nr -k2,2Vr -k3,3Vr | cut -f3
}

# $1 = URL so far (ending in "/"), rest = the remaining path segments. A glob in
# a folder falls back to the next-newest match (up to 3) when the rest finds
# nothing, e.g. a new release folder that so far holds only a beta. Returns 0
# (prints the URL), 1 (nothing matches, or the folder isn't there) or 2 (the
# server gave no answer for a folder: prints that folder, and doesn't fall back,
# since an older folder would offer a downgrade).
resolve_segments() {
    local prefix="$1" seg="$2" cand listing rc
    shift 2
    (( $# )) && seg+="/"
    if [[ "$seg" != *'*'* && "$seg" != *'['* ]]; then
        if (( $# )); then resolve_segments "$prefix$seg" "$@"; else printf '%s\n' "$prefix$seg"; fi
        return
    fi
    listing=$(list_dir "$prefix"); rc=$?
    if (( rc == 2 )); then
        printf '%s\n' "$prefix"
        return 2
    fi
    # not there (404): the caller may try its next candidate
    (( rc == 0 )) || return 1
    while IFS= read -r cand; do
        if (( $# == 0 )); then
            printf '%s\n' "$prefix$cand"
            return 0
        fi
        resolve_segments "$prefix$cand" "$@"; rc=$?
        (( rc == 1 )) || return "$rc"
    done < <(sort_newest "$seg" <<<"$listing" | head -n 3)
    return 1
}

# Expand each glob segment of URL $1 against the server's listings. Prints the
# URL, or with return code 2 the folder that couldn't be listed (see
# resolve_segments). Runs inside $(...), so the caller reports a failure: a say
# here would be captured.
resolve_glob_url() {
    local -a segs
    IFS=/ read -ra segs <<<"${1#*://}"
    resolve_segments "${1%%://*}://${segs[0]}/" "${segs[@]:1}"
}

# The static manager's lookup: one HEAD request that follows redirects. Sets
# asset_url (where it landed), asset_name, remote_length, remote_modified,
# remote_etag, and latest_tag: static-SIZE-ETAG-NAME, leaving out what the
# server didn't send (Beeper and LM Studio put the version in the name, Mudlet
# only in the size). Returns 1 to skip the item.
static_head() {
    local url="$1" curl_out headers part
    # curl -f: a 404 or a timeout leaves nothing to compare, so skip the item
    if ! curl_out=$(curl -fsIL "${CURL_META[@]}" -w '\n%{url_effective}' "$url"); then
        say "⚠ ${PROGRESS_LABEL:-}: could not reach $url, skipping"
        return 1
    fi
    asset_url="${curl_out##*$'\n'}"
    headers="${curl_out%$'\n'*}"

    remote_length=$(awk 'tolower($0) ~ /content-length/{v=$2} END{gsub(/\r/,"",v); print v}' <<<"$headers")
    remote_modified=$(awk 'tolower($0) ~ /last-modified/{sub(/^[^:]*:[ ]*/,""); v=$0} END{gsub(/\r/,"",v); print v}' <<<"$headers")
    # some servers send no size on HEAD; their ETag still tells a new file apart
    remote_etag=$(awk 'tolower($1) == "etag:" {sub(/^[^:]*:[ ]*/,""); v=$0} END{gsub(/\r/,"",v); print v}' <<<"$headers")
    remote_etag="${remote_etag#W/}"

    [[ -z "$asset_url" ]] && asset_url="$url"
    # redirects can land on signed URLs with a long query string
    asset_name="${asset_url%%\?*}"; asset_name="${asset_name##*/}"
    latest_tag="static"
    for part in "$remote_length" "${remote_etag//\"/}" "$asset_name"; do
        [[ -n "$part" ]] && latest_tag+="-$part"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Shared asset resolution
# Sets: latest_tag  asset_url  asset_name  remote_length  remote_modified
#       remote_digest  remote_etag  remote_unchanged (github 304, dateprobe
#       with nothing newer)
# Returns 0 on success, 1 on failure, 2 if GitHub is rate limiting
# ---------------------------------------------------------------------------
resolve_latest_asset() {
    latest_tag="" asset_url="" asset_name="" remote_length="" remote_modified=""
    remote_digest="" remote_etag="" remote_unchanged=0

    case "${manager:-}" in
        github)
            require_keys "github manager" repo || return 1
            local asset_pat
            asset_regex github || return 1

            # Fetch the list, not /latest, to honour allow_prereleases=auto.
            # per_page=100: repos that host several games bury older ones past
            # the default 30.
            local api_url="https://api.github.com/repos/${repo}/releases?per_page=100"
            local release_json rc
            github_releases "$api_url" "${etag:-}"; rc=$?
            if (( rc == 3 )); then
                # 304: the list is exactly what this item saw at its last check
                latest_tag="${current_version:-}" remote_digest="${asset_digest:-}" remote_unchanged=1
                debug "release list unchanged since the last check (304)"
                return 0
            fi
            (( rc )) && return "$rc"

            local result pre all_json page_url="$api_url" first_etag="$remote_etag"

            case "${allow_prereleases:-auto}" in
                false|auto) pre=false ;;
                true)       pre=true ;;
                *)
                    say "⚠ ${PROGRESS_LABEL:-}: allow_prereleases must be auto, false or true (got '${allow_prereleases}'), skipping"
                    return 1
                    ;;
            esac

            # Older releases live on later pages (100 each); fetch them only
            # while nothing matches. The ETag stays page 1's: any new release
            # lands there.
            all_json="$release_json"
            result=$(pick_github_asset "$all_json" "$asset_pat" "$pre")
            while [[ -z "$result" && -n "${GITHUB_NEXT[$page_url]:-}" ]]; do
                page_url="${GITHUB_NEXT[$page_url]}"
                debug "no match yet, fetching the next page of releases"
                github_releases "$page_url" || return
                all_json=$(jq -s 'add' <<<"$all_json$release_json")
                result=$(pick_github_asset "$all_json" "$asset_pat" "$pre")
            done
            remote_etag="$first_etag"
            # auto: a stable release on any page beats a pre-release
            if [[ -z "$result" && "${allow_prereleases:-auto}" == auto ]]; then
                result=$(pick_github_asset "$all_json" "$asset_pat" true)
            fi

            IFS=$'\t' read -r latest_tag asset_url remote_digest <<<"$result"
            asset_name="${asset_url##*/}"
            ;;

        gitlab)
            require_keys "gitlab manager" repo_url || return 1
            local asset_pat
            asset_regex gitlab || return 1
            # accept the project's web address however it was copied
            local release_json project="${repo_url#*://gitlab.com/}"
            project="${project%/}"; project="${project%.git}"
            gitlab_releases "$project" || return
            local result
            result=$(pick_gitlab_asset "$release_json" "$asset_pat")
            # the link's own name: URLs often end in /download or carry ?job=…
            IFS=$'\t' read -r latest_tag asset_url asset_name <<<"$result"
            asset_name="${asset_name//\//_}"
            ;;

        jsonfeed)
            require_keys "jsonfeed manager" feed_url channel arch_key download_base || return 1
            local feed_json
            if ! feed_json=$(curl -fsL "${CURL_META[@]}" "$feed_url"); then
                say "⚠ ${PROGRESS_LABEL:-}: could not fetch $feed_url, skipping"
                return 1
            fi
            latest_tag=$(jq -r --arg ch "$channel" '.[$ch][0].version' <<<"$feed_json")
            asset_name=$(jq -r --arg ch "$channel" --arg arch "$arch_key" \
                '.[$ch][0].appimage[] | select(.["build-id"] | test($arch)) | .filename' <<<"$feed_json")

            if [[ -z "$asset_name" || "$asset_name" == "null" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: could not find AppImage asset for arch $arch_key"
                return 1
            fi
            # {minor_version} is the version's first two parts (3.2 for 3.2.6)
            if [[ "$download_base" == *"{minor_version}"* && ! "$latest_tag" =~ ^([0-9]+\.[0-9]+) ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: no minor version in feed version '$latest_tag', skipping"
                return 1
            fi
            asset_url="${download_base//\{minor_version\}/${BASH_REMATCH[1]:-}}"
            asset_url="${asset_url//\{filename\}/$asset_name}"
            ;;

        static)
            require_keys "static manager" url || return 1
            static_head "$url" || return 1
            ;;

        dirlist)
            require_keys "dirlist manager" url || return 1
            local found glob_rc
            found=$(resolve_glob_url "$url"); glob_rc=$?
            if (( glob_rc == 2 )); then
                say "⚠ ${PROGRESS_LABEL:-}: could not list $found, skipping"
                return 1
            elif (( glob_rc )); then
                say "⚠ ${PROGRESS_LABEL:-}: nothing on the server matches ${url##*/}, skipping"
                return 1
            fi
            asset_url="$found"
            asset_name="${asset_url##*/}"
            # never offer an older build than the installed one (the newest
            # folder 404s while a mirror syncs, say), ranked by the URL's glob
            if [[ -n "${installed_file:-}" && "$asset_name" != "$installed_file" ]] &&
               [[ $(printf '%s\n' "$asset_name" "$installed_file" | sort_newest "${url##*/}" | head -n 1) == "$installed_file" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: the server's newest is $asset_name, older than the installed $installed_file, skipping"
                return 1
            fi
            asset_url+="${download_suffix:-}"
            latest_tag="$asset_name"
            ;;

        dateprobe)
            require_keys "dateprobe manager" url || return 1
            # no listing (Nobara's bucket): try dates from today back, stopping
            # at the installed one; each try is one small HEAD request, on the
            # checksum file when the cfg names one
            local cand probe day day_s now cur_date=""
            [[ "${installed_file:-}" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]] && cur_date="${BASH_REMATCH[0]}"
            printf -v now '%(%s)T' -1
            for (( day = 0; day <= ${probe_days:-90}; day++ )); do
                printf -v day_s '%(%F)T' $(( now - day * 86400 ))
                [[ -n "$cur_date" && "$day_s" < "$cur_date" ]] && break
                cand="${url//\{date\}/$day_s}"
                probe="$cand"
                if [[ -n "${checksum:-}" ]]; then
                    probe="${checksum//\{iso\}/${cand##*/}}"
                    [[ "$probe" == *://* ]] || probe="${cand%/*}/$probe"
                fi
                if curl -fsI "${CURL_META[@]}" -o /dev/null "$probe"; then
                    asset_url="$cand"
                    break
                fi
            done
            if [[ -z "$asset_url" && -n "$cur_date" ]]; then
                # nothing newer: what's installed is the latest
                latest_tag="$installed_file" asset_name="$installed_file" remote_unchanged=1
                debug "no build newer than $cur_date on the server"
                return 0
            elif [[ -z "$asset_url" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: no ${url##*/} found in the last ${probe_days:-90} days, skipping"
                return 1
            fi
            asset_name="${asset_url##*/}"
            latest_tag="$asset_name"
            ;;

        *)
            say "⚠ ${PROGRESS_LABEL:-}: unknown or missing manager '${manager:-}', skipping"
            return 1
            ;;
    esac

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        say "⚠ ${PROGRESS_LABEL:-}: could not resolve download URL, skipping"
        return 1
    fi
    debug "latest ($manager): ${latest_tag:-?}, ${asset_name:-?}${remote_digest:+, ${remote_digest:0:23}…}"
    debug "download URL: $asset_url"
    [[ "$manager" == static ]] && debug "server says ${remote_length:-?} bytes, last modified ${remote_modified:-?}"
    return 0
}

# The version to show for a result: latest_tag, plus file name $1 in brackets
# unless the tag already ends in it (a static tag ends in -NAME, a dirlist tag
# is the name). Not a substring test: pokemon_emerald.apworld ends in
# emerald.apworld.
shown_version() {
    local shown="${latest_tag:-}" file="${1:-}"
    if [[ -n "$file" && "$shown" != "$file" && "$shown" != *"-$file" ]]; then
        shown="${shown:+$shown (}$file${shown:+)}"
    fi
    printf '%s\n' "$shown"
}

# Returns 0 if the item is already up to date. $1 = the installed file, hashed
# once for github cfgs saved before asset_digest, and for ISOs without an
# iso_hash for the checksum's algorithm.
is_up_to_date() {
    local sum
    (( remote_unchanged )) && return 0
    # ISOs compare checksums whatever the manager; algo and want come from
    # isos.sh's item_prepare_check
    if [[ "${ITEM_TYPE:-}" == iso ]]; then
        if [[ "${iso_hash:-}" != "$algo:"* ]]; then
            status "🔍 hashing ${1##*/}"
            iso_hash="$algo:$(hash_file "$algo" "$1")"
        fi
        debug "installed ${iso_hash:0:23}… vs expected $algo ${want:0:16}…"
        [[ "$iso_hash" == "$algo:$want" ]]
        return
    fi
    case "$manager" in
        static)
            debug "size ${remote_length:-?} vs saved ${content_length:-none}, modified ${remote_modified:-?} vs saved ${last_modified:-none}, ETag ${remote_etag:-none} vs saved ${etag:-none}"
            if [[ -z "$remote_length$remote_modified$remote_etag" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: the server gives no size, date or ETag, so it can't tell whether it changed; downloading again"
                return 1
            fi
            # compare only what the server sent and the cfg has saved; with
            # nothing to compare (a new cfg), it isn't up to date
            local known=0 changed=0
            # the version ends in the file's name (static-SIZE-ETAG-NAME): a URL
            # that now lands on another file isn't up to date, even at the same
            # size and date. A version saved before names were in it
            # (static-SIZE or the ETag) can't tell, so the other checks decide.
            local unnamed="static-${remote_length:-${remote_etag//\"/}}"
            if [[ -n "${current_version:-}" && "$current_version" != "$unnamed" &&
                  "$current_version" != *"-$asset_name" ]]; then
                debug "file name changed: now $asset_name, saved version $current_version"
                return 1
            fi
            [[ -n "$remote_length" && -n "${content_length:-}" ]] && { known=1; [[ "$remote_length" == "$content_length" ]] || changed=1; }
            [[ -n "$remote_modified" && -n "${last_modified:-}" ]] && { known=1; [[ "$remote_modified" == "$last_modified" ]] || changed=1; }
            [[ -n "$remote_etag" && -n "${etag:-}" ]] && { known=1; [[ "$remote_etag" == "$etag" ]] || changed=1; }
            (( known && ! changed ))
            ;;
        github)
            debug "tag ${latest_tag:-?} vs installed ${current_version:-none}"
            [[ "$latest_tag" == "${current_version:-}" ]] || return 1
            # same tag, but rolling releases (latest, continuous) re-upload
            if [[ -n "${asset_digest:-}" ]]; then
                debug "same tag; asset digest ${remote_digest:0:23}… vs saved ${asset_digest:0:23}…"
                [[ "$remote_digest" == "$asset_digest" ]]
            elif [[ "$remote_digest" == sha256:* ]]; then
                debug "same tag, no saved digest: hashing the installed file once"
                read -r sum _ < <(sha256sum "$1" 2>/dev/null)
                [[ "sha256:${sum:-}" == "$remote_digest" ]]
            else
                return 0  # no sha256 to compare; adopt the upload time from now on
            fi
            ;;
        *)
            debug "version ${latest_tag:-?} vs installed ${current_version:-none}"
            [[ "$latest_tag" == "${current_version:-}" ]]
            ;;
    esac
}
