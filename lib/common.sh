# common.sh – shared helpers for update-appimages.sh and update-apworlds.sh
# Cfg keys (manager, url, ...) are set by load_cfg through printf -v and today
# by each script's main, so shellcheck can't see them assigned here.
# shellcheck shell=bash disable=SC2154

# ---------------------------------------------------------------------------
# Fallback stubs (overwritten if progress.sh is loaded)
# ---------------------------------------------------------------------------
say()            { printf '%s\n' "$*"; }
status()         { :; }
status_final()   { printf '%s %s\n' "${PROGRESS_LABEL:-}" "$1"; }
commit_final()   { :; }
curl_takeover()  { :; }
curl_handback()  { :; }
curl_abandon()   { :; }
curl_run()       { curl "$@"; }
init_progress()  { :; }
finish_progress(){ :; }
block_redraw()   { :; }

# ---------------------------------------------------------------------------
# Debugging and timing (-d/--debug, or DEBUG=1)
# ---------------------------------------------------------------------------
case "${DEBUG:-0}" in 0|"") DEBUG=0 ;; *) DEBUG=1 ;; esac

# A decision-trace line. It goes through say, so never call it inside $(...)
# (it would be captured) or while curl owns line 2.
debug() {
    (( DEBUG )) || return 0
    say "  · ${PROGRESS_LABEL:-}: $*"
}

# timed LABEL CMD...: run CMD in this shell; with -d, report how long it took,
# measured with bash's time keyword. The report goes to a temp file so it can't
# land in the status block; CMD's own stderr is untouched. An empty LABEL means
# the item being handled.
timed() {
    local label="$1" rc tf took
    shift
    if (( ! DEBUG )); then "$@"; return; fi
    tf=$(mktemp)
    local TIMEFORMAT='%3R %3U %3S'
    { time "$@" 2>&3; } 3>&2 2>"$tf"
    rc=$?
    # bash 5.3 can print a rounding carry as ':' ("0.:0" for 1.00), so read each
    # digit by its value instead of trusting the text
    took=$(awk '
        function sec(x,   i, n, v, p) {
            n = index(x, "."); if (!n) return x + 0
            v = substr(x, 1, n - 1) + 0; p = 1
            for (i = n + 1; i <= length(x); i++) { p /= 10; v += (index("0123456789:", substr(x, i, 1)) - 1) * p }
            return v }
        function fmt(v) { return v >= 60 ? sprintf("%dm%.2fs", int(v / 60), v - 60 * int(v / 60)) : sprintf("%.2fs", v) }
        { printf "%s (user %s, sys %s)", fmt(sec($1)), fmt(sec($2)), fmt(sec($3)) }' "$tf")
    rm -f "$tf"
    commit_final   # the item's result line first, then its time
    say "  · ${label:-${PROGRESS_LABEL:-}}: took $took"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Flags, the same in every updater
# ---------------------------------------------------------------------------
ROOT_ARG=""

# The help text, shared by every updater: each script sets USAGE_ABOUT (what it
# updates and where), USAGE_ITEM (app, world, ISO) and USAGE_ROOT (the rest of
# the -r line, continuation lines indented to the description column).
usage() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS]
$USAGE_ABOUT

Options:
  -c, --check       only look for updates: download and change nothing
  -f, --force       check every $USAGE_ITEM, even ones already checked today
  -r, --root DIR    use DIR instead of $USAGE_ROOT
  -d, --debug       explain each decision and time each $USAGE_ITEM (or DEBUG=1)
  -h, --help        show this help
EOF
}

# Sets the caller's force and check_only, DEBUG, and ROOT_ARG (-r); -h prints
# usage, and a bad option prints it to stderr.
# shellcheck disable=SC2034  # force and check_only are main's locals
parse_flags() {
    while (( $# )); do
        case "$1" in
            -c|--check) check_only=true ;;
            -f|--force) force=true ;;
            -r|--root)
                if [[ -z "${2:-}" ]]; then
                    echo "${0##*/}: $1 needs a folder" >&2; usage >&2; exit 2
                fi
                ROOT_ARG="$2"; shift ;;
            --root=*)   ROOT_ARG="${1#--root=}" ;;
            -d|--debug) DEBUG=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          echo "${0##*/}: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
# A server that accepts the connection and then never answers would hang a run.
# Small requests get a hard limit; downloads only fail when they stall, so a
# big ISO on a slow line still finishes.
CURL_META=(--connect-timeout 20 --max-time 120)
# shellcheck disable=SC2034  # used by the updaters' download lines
CURL_DL=(--connect-timeout 20 --speed-limit 1024 --speed-time 60)

# Each updater's dependencies, by type: app, apw or iso. ;;& goes on to test
# the patterns after it, so a type collects every branch it matches.
require_cmds() {
    local dep
    local -a deps=()
    case "$1" in
        app|apw|iso) deps=(curl) ;;&
        app|apw) deps+=(jq) ;;&
        apw) deps+=(unzip) ;;
        iso) deps+=(sha256sum sha512sum) ;;
    esac
    if (( ${#deps[@]} == 0 )); then
        echo "ERROR: require_cmds: unknown updater type '${1:-}'" >&2
        exit 1
    fi
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || {
            echo "ERROR: required command not found: $dep" >&2
            exit 1
        }
    done
}

# Move a file into $OLD_DIR (creates the directory if needed).
# Caller must set OLD_DIR before calling.
backup_file() {
    mkdir -p "$OLD_DIR"
    mv "$1" "$OLD_DIR/${1##*/}"
}

# ---------------------------------------------------------------------------
# Config handling
# ---------------------------------------------------------------------------
# Every key a cfg may hold. load_cfg sets only these: any other name could
# overwrite one of the scripts' own variables (dir, name, HOME, PATH, ...).
CFG_KEYS=(
    manager repo repo_filename allow_prereleases repo_url
    feed_url channel arch_key download_base url
    content_length last_modified current_version
    install_name apworld_filename installed_file last_checked
    asset_digest etag
    checksum checksum_save download_suffix probe_days
    folder iso_hash checksum_file
)

load_cfg() {
    local cfg_file="$1"
    local line key value

    unset "${CFG_KEYS[@]}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
                value="${value//\\\"/\"}"
            fi
            if [[ " ${CFG_KEYS[*]} " == *" $key "* ]]; then
                printf -v "$key" '%s' "$value"
            else
                say "⚠ ${PROGRESS_LABEL:-}: unknown key '$key' in ${cfg_file##*/}, ignored"
            fi
        fi
    done < "$cfg_file"
}

# True if every named cfg key is set; otherwise says which are missing.
# $1 = what needs them (e.g. "static manager"), rest = the keys.
require_keys() {
    local what="$1" key
    local -a missing=()
    shift
    for key in "$@"; do
        [[ -n "${!key:-}" ]] || missing+=("$key")
    done
    (( ${#missing[@]} == 0 )) && return 0
    say "⚠ ${PROGRESS_LABEL:-}: $what needs ${missing[*]}, skipping"
    return 1
}

update_cfg() {
    local cfg_file="$1"
    shift
    local pair key value escaped

    [[ -s "$cfg_file" && -n "$(tail -c1 "$cfg_file")" ]] && echo >> "$cfg_file"

    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"

        if [[ "$value" =~ [[:space:]\"] ]]; then
            value="\"${value//\"/\\\"}\""
        fi

        if grep -q "^${key}=" "$cfg_file"; then
            escaped="${value//\\/\\\\}"
            escaped="${escaped//&/\\&}"
            escaped="${escaped//|/\\|}"
            sed -i "s|^${key}=.*|${key}=${escaped}|" "$cfg_file"
        else
            echo "${key}=${value}" >> "$cfg_file"
        fi
    done
}

# The file the cfg's installed_file names, if it's still in folder $1: prints its
# full path, or nothing. Runs inside $(...), so it never prints a message.
find_installed() {
    [[ -n "${installed_file:-}" && -f "$1/$installed_file" ]] && printf '%s\n' "$1/$installed_file"
    return 0
}

# Cfg keys the scripts keep up to date themselves, in the order new ones are added.
SAVE_KEYS=(current_version last_checked content_length last_modified asset_digest etag
           installed_file iso_hash checksum_file)

# Save the item's state after a successful check or update; all three updaters
# use this. Each key takes its value from the item being handled: what
# resolve_latest_asset found (cleared for every item), or the cfg variable of the
# same name (installed_file, iso_hash, checksum_file), which load_cfg reloads for
# every item and the caller updates first. Empty values aren't written, so an
# ISO cfg never gets current_version or etag.
save_update_metadata() {
    local cfg="$1" key value
    local -a pairs=()
    for key in "${SAVE_KEYS[@]}"; do
        case "$key" in
            last_checked)    value="$today" ;;
            current_version) value="${latest_tag:-}" ;;
            content_length)  value="${remote_length:-}" ;;
            last_modified)   value="${remote_modified:-}" ;;
            asset_digest)    value="${remote_digest:-}" ;;
            etag)            value="${remote_etag:-}" ;;
            *)               value="${!key:-}" ;;
        esac
        [[ -n "$value" ]] && pairs+=("$key=$value")
    done
    update_cfg "$cfg" "${pairs[@]}"
}

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------
GITHUB_HEADERS=""
GITHUB_CALLS=0
GITHUB_FREE=0
GITHUB_LIMIT=""
GITHUB_REMAINING=""
GITHUB_RESET=""
GITHUB_ETAG=""
GITHUB_LINK_NEXT=""
GITHUB_MOVED=""
GITHUB_RATE_LIMITED=0
declare -A GITHUB_CACHE=() GITHUB_ETAGS=() GITHUB_NEXT=()

# Prints the body, then the HTTP status code on its own last line.
# $2 = optional ETag to send as If-None-Match. -L follows renamed or transferred
# repos; GitHub redirects within api.github.com, so the token stays there.
github_api() {
    local -a args=(-sL "${CURL_META[@]}" -w '\n%{http_code}' -D "$GITHUB_HEADERS")
    [[ -n "${2:-}" ]] && args+=(-H "If-None-Match: $2")
    : > "$GITHUB_HEADERS"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl "${args[@]}" -H @- "$1" <<<"Authorization: Bearer $GITHUB_TOKEN"
    else
        curl "${args[@]}" "$1"
    fi
}

# Sets release_json and remote_etag for $1, fetching each URL once per run.
# Call it directly, never inside $(...), or the cache is lost with the subshell.
# $2 = the ETag this item saved last time; a 304 for it means nothing changed.
# Returns 1 to skip this item, 2 when GitHub is rate limiting us, 3 if unchanged.
github_releases() {
    local api_url="$1" etag="${2:-}" response code when=""
    if [[ -n "${GITHUB_CACHE[$api_url]+set}" ]]; then
        release_json="${GITHUB_CACHE[$api_url]}"
        remote_etag="${GITHUB_ETAGS[$api_url]}"
        debug "GitHub ${api_url#https://api.github.com/}: from this run's cache"
        return 0
    fi
    if (( GITHUB_RATE_LIMITED )); then
        say "⚠ ${PROGRESS_LABEL:-}: GitHub rate limit reached earlier this run, skipping"
        return 2
    fi

    response=$(github_api "$api_url" "$etag")
    read_rate_headers
    code="${response##*$'\n'}"
    release_json="${response%$'\n'*}"
    debug "GitHub ${api_url#https://api.github.com/}${etag:+ (sent ETag)} → HTTP $code, ${GITHUB_REMAINING:-?} requests left"
    [[ -n "$GITHUB_MOVED" ]] && debug "repo ${repo:-} has moved (redirected to $GITHUB_MOVED); consider updating repo= in the cfg"
    # GitHub doesn't count a 304 against the limit when the request carries a token
    if [[ "$code" == 304 && -n "${GITHUB_TOKEN:-}" ]]; then
        GITHUB_FREE=$((GITHUB_FREE + 1))
    else
        GITHUB_CALLS=$((GITHUB_CALLS + 1))
    fi

    case "$code" in
        200)
            remote_etag="$GITHUB_ETAG"
            GITHUB_CACHE[$api_url]="$release_json"
            GITHUB_ETAGS[$api_url]="$remote_etag"
            GITHUB_NEXT[$api_url]="$GITHUB_LINK_NEXT"
            return 0
            ;;
        304)
            remote_etag="$etag"
            return 3
            ;;
        429|403)
            if [[ "$code" == 429 || "${release_json,,}" == *"rate limit"* ]]; then
                GITHUB_RATE_LIMITED=1
                [[ "$GITHUB_RESET" =~ ^[0-9]+$ ]] && printf -v when ' (resets %(%H:%M)T)' "$GITHUB_RESET"
                say "✗ ${PROGRESS_LABEL:-}: GitHub rate limit reached${when}"
                return 2
            fi
            say "⚠ ${PROGRESS_LABEL:-}: GitHub request failed (HTTP 403), skipping"
            ;;
        404)
            say "⚠ ${PROGRESS_LABEL:-}: GitHub repo ${repo:-} not found (HTTP 404), skipping"
            ;;
        000)
            say "⚠ ${PROGRESS_LABEL:-}: no response from GitHub, skipping"
            ;;
        *)
            say "⚠ ${PROGRESS_LABEL:-}: GitHub request failed (HTTP ${code}), skipping"
            ;;
    esac
    return 1
}

# Sets release_json for GitLab project path $1. Returns 1 to skip this item.
# A 429 skips GitLab items only, unlike GitHub's stop: other managers still work.
GITLAB_RATE_LIMITED=0
gitlab_releases() {
    local project="$1" response code
    if (( GITLAB_RATE_LIMITED )); then
        say "⚠ ${PROGRESS_LABEL:-}: GitLab rate limit reached earlier this run, skipping"
        return 1
    fi

    response=$(curl -sL "${CURL_META[@]}" -w '\n%{http_code}' "https://gitlab.com/api/v4/projects/$(urlencode "$project")/releases")
    code="${response##*$'\n'}"
    release_json="${response%$'\n'*}"
    debug "GitLab $project → HTTP $code"

    case "$code" in
        200) return 0 ;;
        429)
            GITLAB_RATE_LIMITED=1
            say "✗ ${PROGRESS_LABEL:-}: GitLab rate limit reached, skipping"
            ;;
        404) say "⚠ ${PROGRESS_LABEL:-}: GitLab project $project not found (HTTP 404), skipping" ;;
        000) say "⚠ ${PROGRESS_LABEL:-}: no response from GitLab, skipping" ;;
        *)   say "⚠ ${PROGRESS_LABEL:-}: GitLab request failed (HTTP $code), skipping" ;;
    esac
    return 1
}

read_rate_headers() {
    local line value next_re='<([^>]*)>; rel="next"'
    GITHUB_ETAG="" GITHUB_LINK_NEXT="" GITHUB_MOVED=""
    while IFS= read -r line; do
        line="${line%$'\r'}"
        value="${line#*:}"; value="${value# }"
        case "${line,,}" in
            x-ratelimit-limit:*)     GITHUB_LIMIT="$value" ;;
            x-ratelimit-remaining:*) GITHUB_REMAINING="$value" ;;
            x-ratelimit-reset:*)     GITHUB_RESET="$value" ;;
            etag:*)                  GITHUB_ETAG="$value" ;;
            link:*)                  [[ "$value" =~ $next_re ]] && GITHUB_LINK_NEXT="${BASH_REMATCH[1]}" ;;
            location:*)              GITHUB_MOVED="$value" ;;
        esac
    done < "$GITHUB_HEADERS"
}

# shellcheck disable=SC2034  # STATUS is drawn by progress.sh
rate_summary() {
    STATUS=""
    (( GITHUB_CALLS + GITHUB_FREE > 0 )) || return 0
    [[ "$GITHUB_LIMIT" =~ ^[0-9]+$ && "$GITHUB_REMAINING" =~ ^[0-9]+$ ]] || return 0
    local warn="" when=""
    (( GITHUB_REMAINING * 10 <= GITHUB_LIMIT )) && warn="⚠ "
    [[ "$GITHUB_RESET" =~ ^[0-9]+$ ]] && printf -v when ', resets %(%H:%M)T' "$GITHUB_RESET"
    STATUS="${warn}GitHub API: $GITHUB_REMAINING/$GITHUB_LIMIT requests left${when} (used $GITHUB_CALLS this run)"
}

# Setup every updater shares: the EXIT trap, which removes the GitHub headers
# file and curl_run's log, then runs the script's own cleanup(); and the GitHub
# token and headers file (update-isos never contacts GitHub, so they simply go
# unused there).
start_run() {
    GITHUB_HEADERS=$(mktemp)
    trap 'rm -f "$GITHUB_HEADERS" "${CURL_LOG:-}"; cleanup' EXIT
    load_github_token
}

# Shared token for both scripts.
# Priority: $GITHUB_TOKEN env var → ~/.config/update-tools/github_token
load_github_token() {
    local token_file="${XDG_CONFIG_HOME:-$HOME/.config}/update-tools/github_token"
    if [[ -z "${GITHUB_TOKEN:-}" && -f "$token_file" ]]; then
        read -r GITHUB_TOKEN < "$token_file"
        [[ "$(stat -c %a "$token_file")" =~ ^[46]00$ ]] \
            || say "⚠ $token_file is readable by other users — run: chmod 600 \"$token_file\""
    fi
}

urlencode() {
    printf '%s' "$1" | sed \
        -e 's|/|%2F|g' \
        -e 's| |%20|g' \
        -e 's|\[|%5B|g' \
        -e 's|\]|%5D|g' \
        -e 's|@|%40|g' \
        -e 's|:|%3A|g'
}

extract_archive() {
    local archive="$1" dest_dir="$2"
    case "$archive" in
        *.tar.gz|*.tgz)   tar -xzf "$archive" -C "$dest_dir" ;;
        *.tar.xz)         tar -xJf "$archive" -C "$dest_dir" ;;
        *.tar.bz2)        tar -xjf "$archive" -C "$dest_dir" ;;
        *.tar)            tar -xf  "$archive" -C "$dest_dir" ;;
        *.zip)            unzip -q -o "$archive" -d "$dest_dir" ;;
        *)                return 1 ;;
    esac
}

# Extract a single member from a zip or tar archive to a destination file.
# Usage: extract_member <archive> <member> <dest_file>
extract_member() {
    local archive="$1" member="$2" dest="$3"
    case "$archive" in
        *.zip)
            # unzip treats member arguments as globs — escape special chars
            local escaped="$member" ch
            for ch in "\\" '[' ']' '*' '?'; do
                escaped="${escaped//"$ch"/\\"$ch"}"
            done
            unzip -p "$archive" "$escaped" > "$dest"
            ;;
        *.tar.gz|*.tgz)
            tar -xzOf "$archive" "$member" > "$dest"
            ;;
        *.tar.xz)
            tar -xJOf "$archive" "$member" > "$dest"
            ;;
        *.tar.bz2)
            tar -xjOf "$archive" "$member" > "$dest"
            ;;
        *.tar)
            tar -xOf "$archive" "$member" > "$dest"
            ;;
        *)
            return 1
            ;;
    esac
    [[ -s "$dest" ]]
}

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
# Shared asset resolution
# Sets: latest_tag  asset_url  asset_name  remote_length  remote_modified
#       remote_digest  remote_etag  remote_unchanged (github only)
# Returns 0 on success, 1 on failure, 2 if GitHub is rate limiting
# ---------------------------------------------------------------------------
resolve_latest_asset() {
    latest_tag="" asset_url="" asset_name="" remote_length="" remote_modified=""
    remote_digest="" remote_etag="" remote_unchanged=0

    case "${manager:-}" in
        github)
            if [[ -z "${repo:-}" || -z "${repo_filename:-}" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: github manager needs repo and repo_filename, skipping"
                return 1
            fi

            # Fetch the list, not /latest, to honour allow_prereleases=auto.
            # per_page=100: repos that host several games bury older ones past the default 30.
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

            local regex result pre all_json page_url="$api_url" first_etag="$remote_etag"
            regex=$(glob_to_regex "$repo_filename")

            case "${allow_prereleases:-auto}" in
                false|auto) pre=false ;;
                true)       pre=true ;;
                *)
                    say "⚠ ${PROGRESS_LABEL:-}: allow_prereleases must be auto, false or true (got '${allow_prereleases}'), skipping"
                    return 1
                    ;;
            esac

            # Older releases live on later pages (100 each); fetch them only while
            # nothing matches. The ETag stays page 1's: any new release lands there.
            all_json="$release_json"
            result=$(pick_github_asset "$all_json" "$regex" "$pre")
            while [[ -z "$result" && -n "${GITHUB_NEXT[$page_url]:-}" ]]; do
                page_url="${GITHUB_NEXT[$page_url]}"
                debug "no match yet, fetching the next page of releases"
                github_releases "$page_url" || return
                all_json=$(jq -s 'add' <<<"$all_json$release_json")
                result=$(pick_github_asset "$all_json" "$regex" "$pre")
            done
            remote_etag="$first_etag"
            # auto: a stable release on any page beats a pre-release
            if [[ -z "$result" && "${allow_prereleases:-auto}" == auto ]]; then
                result=$(pick_github_asset "$all_json" "$regex" true)
            fi

            IFS=$'\t' read -r latest_tag asset_url remote_digest <<<"$result"
            asset_name="${asset_url##*/}"
            ;;

        gitlab)
            if [[ -z "${repo_url:-}" || -z "${repo_filename:-}" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: gitlab manager needs repo_url and repo_filename, skipping"
                return 1
            fi
            # accept the project's web address however it was copied
            local release_json project="${repo_url#*://gitlab.com/}"
            project="${project%/}"; project="${project%.git}"
            gitlab_releases "$project" || return
            local result
            result=$(pick_gitlab_asset "$release_json" "$(glob_to_regex "$repo_filename")")
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
            local curl_out headers
            # -f: a 404 or a timeout means there's nothing to compare, so skip the item
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

            [[ -z "$asset_url" ]] && asset_url="$url"
            # redirects can land on signed URLs with a long query string
            asset_name="${asset_url%%\?*}"; asset_name="${asset_name##*/}"
            # shown as the version; without a size, the ETag (minus quotes) stands in
            remote_etag="${remote_etag#W/}"
            latest_tag="static-${remote_length:-${remote_etag//\"/}}"
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

# Returns 0 if the item is already up to date.
# $1 = the installed file, hashed once for github cfgs saved before asset_digest.
is_up_to_date() {
    local sum
    case "$manager" in
        static)
            debug "size ${remote_length:-?} vs saved ${content_length:-none}, modified ${remote_modified:-?} vs saved ${last_modified:-none}, ETag ${remote_etag:-none} vs saved ${etag:-none}"
            if [[ -z "$remote_length$remote_modified$remote_etag" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: the server gives no size, date or ETag, so it can't tell whether it changed; downloading again"
                return 1
            fi
            # compare only what the server sent and the cfg has saved; with nothing to
            # compare (a new cfg), it isn't up to date
            local known=0 changed=0
            [[ -n "$remote_length" && -n "${content_length:-}" ]] && { known=1; [[ "$remote_length" == "$content_length" ]] || changed=1; }
            [[ -n "$remote_modified" && -n "${last_modified:-}" ]] && { known=1; [[ "$remote_modified" == "$last_modified" ]] || changed=1; }
            [[ -n "$remote_etag" && -n "${etag:-}" ]] && { known=1; [[ "$remote_etag" == "$etag" ]] || changed=1; }
            (( known && ! changed ))
            ;;
        github)
            (( remote_unchanged )) && return 0
            debug "tag ${latest_tag:-?} vs installed ${current_version:-none}"
            [[ "$latest_tag" == "${current_version:-}" ]] || return 1
            # same tag, but rolling releases (latest, continuous) re-upload the asset
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
