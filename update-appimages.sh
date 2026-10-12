#!/usr/bin/env bash
# ~/AppImages/update-appimages.sh
set -uo pipefail

APPIMAGES_DIR="$HOME/AppImages"
CFG_DIR="$APPIMAGES_DIR/.cfg"
ICONS_DIR="$APPIMAGES_DIR/.icons"
OLD_DIR="$APPIMAGES_DIR/.old"

# ---------------------------------------------------------------------------
# Live status block, two lines, redrawn in place with ANSI cursor codes:
#
#   AppName <status>
#   [####................] 20% (1/5)      <- curl's own bar takes this line
#                                             over while a download runs
#
# Only active on an interactive terminal; cron/redirected output stays plain.
# The cursor always rests at the end of line 2 while the block is on screen.
#   say()          permanent line (warnings/errors) printed above the block
#   status()       replaces the status text on line 1
#   status_final() same, and remembers it as the app's result; that result
#                  is written to the scrollback when the app is finished
# ---------------------------------------------------------------------------
PROGRESS_ON=0
PROGRESS_TOTAL=0
PROGRESS_DONE=0
PROGRESS_LABEL=""       # app currently being handled (start of line 1)
PROGRESS_COLS=80
STATUS=""               # status text on line 1
FINAL_STATUS=""         # the app's end result, kept until it is committed
BLOCK_DRAWN=0

block_erase() {
    (( PROGRESS_ON && BLOCK_DRAWN )) || return 0
    # clear line 2, step up, clear line 1: cursor ends at the block's top
    printf '\r\033[K\033[1A\r\033[K'
    BLOCK_DRAWN=0
}

block_draw() {
    (( PROGRESS_ON )) || return 0
    local percent filled fill empty line1
    percent=$(( PROGRESS_DONE * 100 / PROGRESS_TOTAL ))
    filled=$(( PROGRESS_DONE * 20 / PROGRESS_TOTAL ))
    printf -v fill '%*s' "$filled" ''
    printf -v empty '%*s' "$(( 20 - filled ))" ''
    line1="$PROGRESS_LABEL${STATUS:+ $STATUS}"
    printf '%s\n[%s%s] %d%% (%d/%d)' "${line1:0:PROGRESS_COLS-4}" \
        "${fill// /#}" "${empty// /.}" "$percent" "$PROGRESS_DONE" "$PROGRESS_TOTAL"
    BLOCK_DRAWN=1
}

block_redraw() { block_erase; block_draw; }

# Permanent line above the block (drop-in for echo on warnings/errors).
say() {
    block_erase
    printf '%s\n' "$*"
    block_draw
}

# Transient status on line 1. Without a terminal there is no block, so each
# status is just logged as a plain "AppName status" line instead.
status() {
    STATUS="$1"
    if (( PROGRESS_ON )); then
        block_redraw
    else
        printf '%s %s\n' "$PROGRESS_LABEL" "$1"
    fi
}

status_final() {
    FINAL_STATUS="$1"
    status "$1"
}

# Write the finished app's result into the scrollback above the block. The
# caller redraws the block right after (it is left erased here).
commit_final() {
    [[ -n "$FINAL_STATUS" ]] || return 0
    if (( PROGRESS_ON )); then
        block_erase
        printf '%s %s\n' "$PROGRESS_LABEL" "$FINAL_STATUS"
    fi
    FINAL_STATUS=""
}

# curl's --progress-bar replaces line 2 while it downloads, then ends its
# line with a newline: step back up onto it and redraw the block over it.
curl_takeover() { (( PROGRESS_ON )) && printf '\r\033[K'; return 0; }
curl_handback() { if (( PROGRESS_ON )); then printf '\033[1A'; block_redraw; fi; }
# After a failed curl we can't know how many lines it printed: forget the old
# block and let the next say()/status() start a fresh one below.
curl_abandon()  { if (( PROGRESS_ON )); then BLOCK_DRAWN=0; printf '\r'; fi; }

# GitHub API GET. With a token the rate limit is 5000/hour instead of 60.
# The header is fed to curl on stdin (-H @-) rather than as an argument, so
# the token never shows up in `ps` output. Response headers are dumped to
# $GITHUB_HEADERS so the rate-limit counters can be read afterwards (this
# runs inside $(...), so it can't set variables itself).
GITHUB_HEADERS=""       # temp file, created in the main section
GITHUB_CALLS=0          # API requests made by this run
GITHUB_LIMIT=""
GITHUB_REMAINING=""
GITHUB_RESET=""         # epoch seconds

github_api() {
    : > "$GITHUB_HEADERS"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -s -D "$GITHUB_HEADERS" -H @- "$1" <<<"Authorization: Bearer $GITHUB_TOKEN"
    else
        curl -s -D "$GITHUB_HEADERS" "$1"
    fi
}

# Pick the rate-limit counters out of the last response's headers. GitHub
# sends them on every response, so this costs no extra requests.
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

# Sets STATUS to a one-line summary of the GitHub request budget, or to
# nothing if no GitHub request was made. Warns when 10% or less is left.
rate_summary() {
    STATUS=""
    (( GITHUB_CALLS > 0 )) || return 0
    [[ "$GITHUB_LIMIT" =~ ^[0-9]+$ && "$GITHUB_REMAINING" =~ ^[0-9]+$ ]] || return 0
    local warn="" when=""
    (( GITHUB_REMAINING * 10 <= GITHUB_LIMIT )) && warn="⚠ "
    [[ "$GITHUB_RESET" =~ ^[0-9]+$ ]] && printf -v when ', resets %(%H:%M)T' "$GITHUB_RESET"
    STATUS="${warn}GitHub API: $GITHUB_REMAINING/$GITHUB_LIMIT requests left${when} (used $GITHUB_CALLS this run)"
}

# Simple URL-encoder (enough for GitLab project paths)
urlencode() {
    sed \
        -e 's|/|%2F|g' \
        -e 's| |%20|g' \
        -e 's|\[|%5B|g' \
        -e 's|\]|%5D|g' \
        -e 's|@|%40|g' \
        -e 's|:|%3A|g' <<<"$1"
}

extract_archive() {
    local archive="$1" dest_dir="$2"
    case "$archive" in
        *.tar.gz|*.tgz)   tar -xzf "$archive" -C "$dest_dir" ;;
        *.tar.xz)         tar -xJf "$archive" -C "$dest_dir" ;;
        *.tar.bz2)        tar -xjf "$archive" -C "$dest_dir" ;;
        *.tar)            tar -xf "$archive" -C "$dest_dir" ;;
        *.zip)            unzip -q -o "$archive" -d "$dest_dir" ;;
        *)                return 1 ;;
    esac
}

backup_appimage() {
    local appimage_file="$1"
    mkdir -p "$OLD_DIR"
    mv "$appimage_file" "$OLD_DIR/${appimage_file##*/}"
}

desktop_entry_path() {
    echo "$HOME/.local/share/applications/${1}.desktop"
}

ensure_desktop_entry() {
    local app_name="$1" appimage_file="$2"
    if [[ ! -f "$(desktop_entry_path "$app_name")" ]]; then
        generate_desktop_entry "$app_name" "$appimage_file"
    fi
}

icon_exists() {
    local dir="$1" name="$2"
    find -L "$dir" -maxdepth 1 \
        \( -iname "${name}.png" -o -iname "${name}.svg" \
           -o -iname "${name}.xpm" -o -iname "${name}.ico" \) \
        -print -quit 2>/dev/null
}

find_icon() {
    local dir="$1" maxdepth="$2"
    local -a find_args=(-L "$dir")
    [[ -n "$maxdepth" ]] && find_args+=(-maxdepth "$maxdepth")
    find_args+=(\( -iname "*.png" -o -iname "*.svg" \) -print -quit)
    find "${find_args[@]}" 2>/dev/null
}

generate_desktop_entry() {
    local app_name="$1" appimage_file="$2"

    mkdir -p "$ICONS_DIR"
    local icon_dest="$ICONS_DIR/$app_name"
    local desktop_dest
    desktop_dest=$(desktop_entry_path "$app_name")

    local tmp_extract
    tmp_extract=$(mktemp -d)

    if ! (cd "$tmp_extract" && "$appimage_file" --appimage-extract &>/dev/null); then
        say "  ✗ Failed to extract AppImage contents for $app_name"
        rm -rf "$tmp_extract"
        return 1
    fi

    local squashfs_root="$tmp_extract/squashfs-root"

    local embedded_desktop
    embedded_desktop=$(find -L "$squashfs_root" -maxdepth 1 -iname "*.desktop" -print -quit)
    [[ -z "$embedded_desktop" ]] && \
        embedded_desktop=$(find "$squashfs_root" -maxdepth 3 -iname "*.desktop" -print -quit)

    if [[ -z "$(icon_exists "$ICONS_DIR" "$app_name")" ]]; then
        local -a icon_tiers=(
            "$squashfs_root:1"
            "$squashfs_root/usr/share/icons:"
            "$squashfs_root:"
        )
        local icon_src="" tier dir maxdepth
        for tier in "${icon_tiers[@]}"; do
            dir="${tier%%:*}"
            maxdepth="${tier#*:}"
            icon_src=$(find_icon "$dir" "$maxdepth")
            [[ -n "$icon_src" ]] && break
        done

        if [[ -n "$icon_src" ]]; then
            cp "$icon_src" "${icon_dest}.${icon_src##*.}"
            status "🖼 icon extracted"
        else
            say "  ⚠ No icon found for $app_name"
        fi
    fi

    local icon_path
    icon_path=$(icon_exists "$ICONS_DIR" "$app_name")

    if [[ -n "$embedded_desktop" ]]; then
        sed \
            -e "s|^Icon=.*|Icon=${icon_path:-}|" \
            -e "s|^TryExec=.*|TryExec=$appimage_file|" \
            -e "s|^Exec=.*|Exec=env DESKTOPINTEGRATION=1 $appimage_file %f|" \
            "$embedded_desktop" > "$desktop_dest"
        status "󰴚 desktop entry built from embedded metadata"
    else
        cat > "$desktop_dest" <<EOF
[Desktop Entry]
Type=Application
Name=$app_name
Icon=${icon_path:-}
TryExec=$appimage_file
Exec=env DESKTOPINTEGRATION=1 $appimage_file %f
Categories=Utility;
X-AppImage-Name=$app_name
EOF
        say "  ⚠ No embedded .desktop found, generated minimal entry for $app_name"
    fi

    rm -rf "$tmp_extract"
}

# Update one or more key=value lines in a .cfg file using sed
update_cfg() {
    local cfg_file="$1"
    shift
    local pair key value escaped
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"

        # Quote the value if it contains spaces or special characters
        if [[ "$value" =~ [[:space:]\"] ]]; then
            value="\"${value//\"/\\\"}\""
        fi

        if grep -q "^${key}=" "$cfg_file"; then
            # Escape \, &, and | for sed's replacement text
            escaped="${value//\\/\\\\}"
            escaped="${escaped//&/\\&}"
            escaped="${escaped//|/\\|}"
            sed -i "s|^${key}=.*|${key}=${escaped}|" "$cfg_file"
        else
            echo "${key}=${value}" >> "$cfg_file"
        fi
    done
}

# Safe config loader — never executes the file
load_cfg() {
    local cfg_file="$1"
    local line key value

    unset manager repo repo_filename allow_prereleases \
          repo_url feed_url channel arch_key download_base \
          url content_length last_modified current_version

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Strip one layer of surrounding double quotes and unescape \"
            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
                value="${value//\\\"/\"}"
            fi
            printf -v "$key" '%s' "$value"
        fi
    done < "$cfg_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$CFG_DIR" "$ICONS_DIR" "$OLD_DIR"

GITHUB_HEADERS=$(mktemp)
trap 'rm -f "$GITHUB_HEADERS"' EXIT

# Optional GitHub token: $GITHUB_TOKEN if set, otherwise the first line of
# ~/.config/update-appimages/github_token. Without one, GitHub's anonymous
# limit (60 requests/hour) applies.
GITHUB_TOKEN_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/update-appimages/github_token"
if [[ -z "${GITHUB_TOKEN:-}" && -f "$GITHUB_TOKEN_FILE" ]]; then
    read -r GITHUB_TOKEN < "$GITHUB_TOKEN_FILE"
    [[ "$(stat -c %a "$GITHUB_TOKEN_FILE")" =~ ^[46]00$ ]] \
        || say "⚠ $GITHUB_TOKEN_FILE is readable by other users — run: chmod 600 \"$GITHUB_TOKEN_FILE\""
fi

shopt -s nullglob
cfg_files=("$CFG_DIR"/*.appimage.cfg)
PROGRESS_TOTAL=${#cfg_files[@]}
if [[ -t 1 ]] && (( PROGRESS_TOTAL > 0 )); then
    PROGRESS_ON=1
    term_cols=0
    read -r _ term_cols < <(stty size 2>/dev/null)
    (( term_cols > 0 )) && PROGRESS_COLS=$term_cols
fi

# The bar is driven by the loop index (= apps already finished), drawn at the
# top of each iteration — so every `continue` below still advances it.
for i in "${!cfg_files[@]}"; do
    commit_final        # keep the previous app's result in the scrollback
    cfg_file="${cfg_files[$i]}"
    app_name="${cfg_file##*/}"
    app_name="${app_name%.appimage.cfg}"

    PROGRESS_DONE=$i
    PROGRESS_LABEL="$app_name"
    STATUS=""
    block_redraw

    load_cfg "$cfg_file"

    appimage_file=$(find "$APPIMAGES_DIR" -maxdepth 1 -iname "${app_name}.appimage" -type f -print -quit)

    if [[ -z "$appimage_file" ]]; then
        say "⚠ $app_name: no AppImage found, skipping"
        continue
    fi

    remote_length=""
    remote_modified=""
    latest_tag=""
    asset_url=""
    asset_name=""

    case "${manager:-}" in
        github)
            api_url="https://api.github.com/repos/${repo}/releases"
            [[ "${allow_prereleases:-false}" == "false" ]] && api_url="$api_url/latest"

            GITHUB_CALLS=$((GITHUB_CALLS + 1))
            release_json=$(github_api "$api_url")
            read_rate_headers
            latest_tag=$(jq -r 'if type=="array" then .[0].tag_name else .tag_name end' <<<"$release_json")
            asset_url=$(jq -r --arg pat "${repo_filename}" '
                (if type=="array" then .[0] else . end).assets[]
                | select(.name | test($pat | gsub("\\*"; ".*")))
                | .browser_download_url' <<<"$release_json" | head -n 1)
            asset_name="${asset_url##*/}"
            ;;
        gitlab)
            project_path="${repo_url#https://gitlab.com/}"
            encoded_path=$(urlencode "$project_path")

            release_json=$(curl -s "https://gitlab.com/api/v4/projects/${encoded_path}/releases")
            latest_tag=$(jq -r '.[0].tag_name' <<<"$release_json")
            asset_url=$(jq -r --arg pat "${repo_filename}" '
                .[0].assets.links[]
                | select(.name | test($pat | gsub("\\*"; ".*")))
                | .direct_asset_url' <<<"$release_json" | head -n 1)
            asset_name="${asset_url##*/}"
            ;;
        jsonfeed)
            feed_json=$(curl -s "$feed_url")
            latest_tag=$(jq -r --arg ch "$channel" '.[$ch][0].version' <<<"$feed_json")
            asset_name=$(jq -r --arg ch "$channel" --arg arch "$arch_key" \
                '.[$ch][0].appimage[] | select(.["build-id"] | test($arch)) | .filename' <<<"$feed_json")

            if [[ -z "$asset_name" || "$asset_name" == "null" ]]; then
                say "⚠ $app_name: could not find AppImage asset for arch $arch_key"
                continue
            fi

            [[ "$latest_tag" =~ ^([0-9]+\.[0-9]+) ]]
            minor_version="${BASH_REMATCH[1]}"
            asset_url=$(sed -e "s|{minor_version}|$minor_version|" \
                            -e "s|{filename}|$asset_name|" <<<"$download_base")
            ;;
        static)
            # Single curl: headers + final effective URL
            # (kept as one newline-separated string — joining an array
            # with ${arr[*]} would collapse the headers onto a single line)
            curl_out=$(curl -sIL -w '\n%{url_effective}' "$url")
            asset_url="${curl_out##*$'\n'}"
            headers="${curl_out%$'\n'*}"

            remote_length=$(awk 'tolower($0) ~ /content-length/{v=$2} END{gsub(/\r/,"",v); print v}' <<<"$headers")
            remote_modified=$(awk 'tolower($0) ~ /last-modified/{sub(/^[^:]*:[ ]*/,""); v=$0} END{gsub(/\r/,"",v); print v}' <<<"$headers")

            [[ -z "$asset_url" ]] && asset_url="$url"
            asset_name="${asset_url##*/}"
            latest_tag="static-$remote_length"
            ;;
        *)
            say "⚠ $app_name: unknown or missing manager '${manager:-}', skipping"
            continue
            ;;
    esac

    # Unified "up to date" check
    if [[ "$manager" == "static" ]]; then
        if [[ -n "$remote_length" && "$remote_length" == "${content_length:-}" && \
              "$remote_modified" == "${last_modified:-}" ]]; then
            status_final "✓ up to date (unchanged)"
            ensure_desktop_entry "$app_name" "$appimage_file"
            continue
        fi
    elif [[ "$latest_tag" == "${current_version:-}" ]]; then
        status_final "✓ up to date ($current_version)"
        ensure_desktop_entry "$app_name" "$appimage_file"
        continue
    fi

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        say "⚠ $app_name: could not resolve download URL, skipping"
        continue
    fi

    status "⬆ updating"
    tmp_download="$(mktemp --suffix="-$asset_name")"

    # curl's own bar replaces the overall bar on line 2 for the download
    curl_takeover
    if ! curl -L --progress-bar "$asset_url" -o "$tmp_download"; then
        curl_abandon
        say "  ✗ Failed to download update for $app_name"
        rm -f "$tmp_download"
        continue
    fi
    curl_handback

    tmp_extract_dir=""
    new_appimage="$tmp_download"
    case "$asset_name" in
        *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar|*.zip)
            tmp_extract_dir=$(mktemp -d)
            if ! extract_archive "$tmp_download" "$tmp_extract_dir"; then
                say "  ✗ Failed to extract archive for $app_name"
                rm -f "$tmp_download"
                rm -rf "$tmp_extract_dir"
                continue
            fi
            new_appimage=$(find "$tmp_extract_dir" -iname "*.appimage" -type f -print -quit)
            if [[ -z "$new_appimage" ]]; then
                say "  ✗ No AppImage found inside extracted archive for $app_name"
                rm -f "$tmp_download"
                rm -rf "$tmp_extract_dir"
                continue
            fi
            ;;
    esac

    backup_appimage "$appimage_file"
    mv "$new_appimage" "$appimage_file"
    chmod +x "$appimage_file"
    rm -f "$tmp_download"
    [[ -n "$tmp_extract_dir" ]] && rm -rf "$tmp_extract_dir"

    generate_desktop_entry "$app_name" "$appimage_file"

    # Persist new metadata
    if [[ "$manager" == "static" ]]; then
        update_cfg "$cfg_file" \
            "current_version=$latest_tag" \
            "content_length=$remote_length" \
            "last_modified=$remote_modified"
    else
        update_cfg "$cfg_file" "current_version=$latest_tag"
    fi

    status_final "✓ updated to $latest_tag"
done

# Final state: all apps finished. Leave the bar at 100% and end its line.
commit_final
PROGRESS_DONE=$PROGRESS_TOTAL
PROGRESS_LABEL="Done"
rate_summary
block_redraw
if (( PROGRESS_ON )); then
    printf '\n'
elif [[ -n "$STATUS" ]]; then
    printf '%s\n' "$STATUS"
fi
