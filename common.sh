# common.sh – shared helpers for update-appimages.sh and update-apworlds.sh

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
init_progress()  { :; }
finish_progress(){ :; }
block_redraw()   { :; }

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
require_cmds() {
    local dep
    for dep in "$@"; do
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
load_cfg() {
    local cfg_file="$1"
    local line key value

    unset manager repo repo_filename allow_prereleases repo_url \
          feed_url channel arch_key download_base url \
          content_length last_modified current_version \
          install_name apworld_filename installed_file last_checked

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
            printf -v "$key" '%s' "$value"
        fi
    done < "$cfg_file"
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

# Save the common metadata after a successful update/check.
# Extra key=value pairs can be passed (e.g. installed_file=foo.apworld).
save_update_metadata() {
    local cfg="$1"
    shift
    if [[ "$manager" == "static" ]]; then
        update_cfg "$cfg" \
            "current_version=$latest_tag" \
            "last_checked=$today" \
            "content_length=$remote_length" \
            "last_modified=$remote_modified" \
            "$@"
    else
        update_cfg "$cfg" \
            "current_version=$latest_tag" \
            "last_checked=$today" \
            "$@"
    fi
}

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------
GITHUB_HEADERS=""
GITHUB_CALLS=0
GITHUB_LIMIT=""
GITHUB_REMAINING=""
GITHUB_RESET=""

github_api() {
    : > "$GITHUB_HEADERS"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -s -D "$GITHUB_HEADERS" -H @- "$1" <<<"Authorization: Bearer $GITHUB_TOKEN"
    else
        curl -s -D "$GITHUB_HEADERS" "$1"
    fi
}

read_rate_headers() {
    local line value
    while IFS= read -r line; do
        line="${line%$'\r'}"
        value="${line#*:}"; value="${value# }"
        case "${line,,}" in
            x-ratelimit-limit:*)     GITHUB_LIMIT="$value" ;;
            x-ratelimit-remaining:*) GITHUB_REMAINING="$value" ;;
            x-ratelimit-reset:*)     GITHUB_RESET="$value" ;;
        esac
    done < "$GITHUB_HEADERS"
}

rate_summary() {
    STATUS=""
    (( GITHUB_CALLS > 0 )) || return 0
    [[ "$GITHUB_LIMIT" =~ ^[0-9]+$ && "$GITHUB_REMAINING" =~ ^[0-9]+$ ]] || return 0
    local warn="" when=""
    (( GITHUB_REMAINING * 10 <= GITHUB_LIMIT )) && warn="⚠ "
    [[ "$GITHUB_RESET" =~ ^[0-9]+$ ]] && printf -v when ', resets %(%H:%M)T' "$GITHUB_RESET"
    STATUS="${warn}GitHub API: $GITHUB_REMAINING/$GITHUB_LIMIT requests left${when} (used $GITHUB_CALLS this run)"
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
glob_to_regex() {
    local p="$1"
    p="${p//./\\.}"
    p="${p//\*/.*}"
    printf '^%s$' "$p"
}

# Print "<tag>\t<url>" for the newest suitable release that has a matching asset.
# $3 = true|false → whether pre-releases are eligible.
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
              | [$r.tag_name, $a.browser_download_url] ]
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
              | [$r.tag_name, ($a.direct_asset_url // $a.url)] ]
            | (.[0] // empty) | @tsv
        end' <<<"$json" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Shared asset resolution
# Sets: latest_tag  asset_url  asset_name  remote_length  remote_modified
# Returns 0 on success, 1 on failure
# ---------------------------------------------------------------------------
resolve_latest_asset() {
    latest_tag="" asset_url="" asset_name="" remote_length="" remote_modified=""

    case "${manager:-}" in
        github)
            if [[ -z "${repo:-}" || -z "${repo_filename:-}" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: github manager needs repo and repo_filename, skipping"
                return 1
            fi

            local api_url="https://api.github.com/repos/${repo}/releases"
            # Always fetch the full list so we can honour allow_prereleases=auto
            GITHUB_CALLS=$((GITHUB_CALLS + 1))
            local release_json
            release_json=$(github_api "$api_url")
            read_rate_headers

            local regex result
            regex=$(glob_to_regex "$repo_filename")

            case "${allow_prereleases:-auto}" in
                false) result=$(pick_github_asset "$release_json" "$regex" false) ;;
                true)  result=$(pick_github_asset "$release_json" "$regex" true)  ;;
                auto)  result=$(pick_github_asset "$release_json" "$regex" false)
                       [[ -z "$result" ]] && result=$(pick_github_asset "$release_json" "$regex" true) ;;
                *)
                    say "⚠ ${PROGRESS_LABEL:-}: allow_prereleases must be auto, false or true (got '${allow_prereleases}'), skipping"
                    return 1
                    ;;
            esac

            IFS=$'\t' read -r latest_tag asset_url <<<"$result"
            asset_name="${asset_url##*/}"
            ;;

        gitlab)
            if [[ -z "${repo_url:-}" || -z "${repo_filename:-}" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: gitlab manager needs repo_url and repo_filename, skipping"
                return 1
            fi
            local project_path="${repo_url#https://gitlab.com/}"
            local encoded_path
            encoded_path=$(urlencode "$project_path")

            local release_json
            release_json=$(curl -s "https://gitlab.com/api/v4/projects/${encoded_path}/releases")
            local result
            result=$(pick_gitlab_asset "$release_json" "$(glob_to_regex "$repo_filename")")
            IFS=$'\t' read -r latest_tag asset_url <<<"$result"
            asset_name="${asset_url##*/}"
            ;;

        jsonfeed)
            local feed_json
            feed_json=$(curl -s "$feed_url")
            latest_tag=$(jq -r --arg ch "$channel" '.[$ch][0].version' <<<"$feed_json")
            asset_name=$(jq -r --arg ch "$channel" --arg arch "$arch_key" \
                '.[$ch][0].appimage[] | select(.["build-id"] | test($arch)) | .filename' <<<"$feed_json")

            if [[ -z "$asset_name" || "$asset_name" == "null" ]]; then
                say "⚠ ${PROGRESS_LABEL:-}: could not find AppImage asset for arch $arch_key"
                return 1
            fi
            [[ "$latest_tag" =~ ^([0-9]+\.[0-9]+) ]]
            asset_url="${download_base//\{minor_version\}/${BASH_REMATCH[1]}}"
            asset_url="${asset_url//\{filename\}/$asset_name}"
            ;;

        static)
            local curl_out headers
            curl_out=$(curl -sIL -w '\n%{url_effective}' "$url")
            asset_url="${curl_out##*$'\n'}"
            headers="${curl_out%$'\n'*}"

            remote_length=$(awk 'tolower($0) ~ /content-length/{v=$2} END{gsub(/\r/,"",v); print v}' <<<"$headers")
            remote_modified=$(awk 'tolower($0) ~ /last-modified/{sub(/^[^:]*:[ ]*/,""); v=$0} END{gsub(/\r/,"",v); print v}' <<<"$headers")

            [[ -z "$asset_url" ]] && asset_url="$url"
            # redirects can land on signed URLs with a long query string
            asset_name="${asset_url%%\?*}"; asset_name="${asset_name##*/}"
            latest_tag="static-$remote_length"
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
    return 0
}

# Returns 0 if the item is already up to date
is_up_to_date() {
    if [[ "$manager" == "static" ]]; then
        [[ -n "$remote_length" && "$remote_length" == "${content_length:-}" && \
           "$remote_modified" == "${last_modified:-}" ]]
    else
        [[ "$latest_tag" == "${current_version:-}" ]]
    fi
}
