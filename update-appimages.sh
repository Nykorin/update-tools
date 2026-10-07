#!/usr/bin/env bash
# ~/AppImages/update-appimages.sh
set -uo pipefail

APPIMAGES_DIR="$HOME/AppImages"
CFG_DIR="$APPIMAGES_DIR/.cfg"
ICONS_DIR="$APPIMAGES_DIR/.icons"
OLD_DIR="$APPIMAGES_DIR/.old"

# Simple URL-encoder (enough for GitLab project paths)
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
        echo "  ✗ Failed to extract AppImage contents for $app_name"
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
            echo "  🖼 Extracted icon for $app_name"
        else
            echo "  ⚠ No icon found for $app_name"
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
        echo "  ✓ Desktop entry built from embedded metadata for $app_name"
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
        echo "  ⚠ No embedded .desktop found, generated minimal entry for $app_name"
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

for cfg_file in "$CFG_DIR"/*.appimage.cfg; do
    [[ -f "$cfg_file" ]] || continue

    app_name=$(basename "$cfg_file")
    app_name="${app_name%.appimage.cfg}"

    load_cfg "$cfg_file"

    appimage_file=$(find "$APPIMAGES_DIR" -maxdepth 1 -iname "${app_name}.appimage" -type f -print -quit)

    if [[ -z "$appimage_file" ]]; then
        echo "⚠ $app_name: no AppImage found, skipping"
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

            release_json=$(curl -s "$api_url")
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
                echo "⚠ $app_name: could not find AppImage asset for arch $arch_key"
                continue
            fi

            [[ "$latest_tag" =~ ^([0-9]+\.[0-9]+) ]]
            minor_version="${BASH_REMATCH[1]}"
            asset_url=$(sed -e "s|{minor_version}|$minor_version|" \
                            -e "s|{filename}|$asset_name|" <<<"$download_base")
            ;;
        static)
            # Single curl: headers + final effective URL
            mapfile -t curl_out < <(curl -sIL -w '\n%{url_effective}' "$url")
            asset_url="${curl_out[-1]}"
            unset 'curl_out[-1]'
            headers="${curl_out[*]}"

            remote_length=$(awk 'tolower($0) ~ /content-length/{v=$2} END{gsub(/\r/,"",v); print v}' <<<"$headers")
            remote_modified=$(awk 'tolower($0) ~ /last-modified/{sub(/^[^:]*:[ ]*/,""); v=$0} END{gsub(/\r/,"",v); print v}' <<<"$headers")

            [[ -z "$asset_url" ]] && asset_url="$url"
            asset_name="${asset_url##*/}"
            latest_tag="static-$remote_length"
            ;;
        *)
            echo "⚠ $app_name: unknown or missing manager '${manager:-}', skipping"
            continue
            ;;
    esac

    # Unified "up to date" check
    if [[ "$manager" == "static" ]]; then
        if [[ -n "$remote_length" && "$remote_length" == "${content_length:-}" && \
              "$remote_modified" == "${last_modified:-}" ]]; then
            echo "✓ $app_name is up to date (unchanged)"
            ensure_desktop_entry "$app_name" "$appimage_file"
            continue
        fi
    elif [[ "$latest_tag" == "${current_version:-}" ]]; then
        echo "✓ $app_name is up to date ($current_version)"
        ensure_desktop_entry "$app_name" "$appimage_file"
        continue
    fi

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        echo "⚠ $app_name: could not resolve download URL, skipping"
        continue
    fi

    echo "⬆ Updating $app_name..."
    tmp_download="$(mktemp --suffix="-$asset_name")"

    if ! curl -L --progress-bar "$asset_url" -o "$tmp_download"; then
        echo "  ✗ Failed to download update for $app_name"
        rm -f "$tmp_download"
        continue
    fi

    tmp_extract_dir=""
    new_appimage="$tmp_download"
    case "$asset_name" in
        *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar|*.zip)
            tmp_extract_dir=$(mktemp -d)
            if ! extract_archive "$tmp_download" "$tmp_extract_dir"; then
                echo "  ✗ Failed to extract archive for $app_name"
                rm -f "$tmp_download"
                rm -rf "$tmp_extract_dir"
                continue
            fi
            new_appimage=$(find "$tmp_extract_dir" -iname "*.appimage" -type f -print -quit)
            if [[ -z "$new_appimage" ]]; then
                echo "  ✗ No AppImage found inside extracted archive for $app_name"
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

    echo "  ✓ $app_name updated to $latest_tag"
done
