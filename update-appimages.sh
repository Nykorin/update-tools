#!/usr/bin/env bash
# ~/AppImages/update-appimages.sh
set -uo pipefail

APPIMAGES_DIR="$HOME/AppImages"

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

ICONS_DIR="$APPIMAGES_DIR/.icons"
JSON_DIR="$APPIMAGES_DIR/.json"
OLD_DIR="$APPIMAGES_DIR/.old"

backup_appimage() {
    local appimage_file="$1"
    mkdir -p "$OLD_DIR"
    mv "$appimage_file" "$OLD_DIR/$(basename -- "$appimage_file")"
}

icon_exists() {
    local dir="$1" name="$2"
    find -L "$dir" -maxdepth 1 \( -iname "${name}.png" -o -iname "${name}.svg" -o -iname "${name}.xpm" -o -iname "${name}.ico" \) 2>/dev/null | head -n 1
}

# Searches one icon tier: $dir, down to $maxdepth levels (empty = no
# limit). -L follows symlinks throughout, since an AppImage's extracted
# squashfs-root is sometimes itself a symlink to AppDir. Sorted
# descending so the pick is deterministic rather than filesystem-order.
find_icon() {
    local dir="$1" maxdepth="$2"
    local -a find_args=(-L "$dir")
    [[ -n "$maxdepth" ]] && find_args+=(-maxdepth "$maxdepth")
    find_args+=(\( -iname "*.png" -o -iname "*.svg" \))
    find "${find_args[@]}" 2>/dev/null | sort -r | head -n 1
}

generate_desktop_entry() {
    local app_name="$1" appimage_file="$2"

    mkdir -p "$ICONS_DIR"
    local icon_dest="$ICONS_DIR/$app_name"
    local desktop_dest="$HOME/.local/share/applications/${app_name}.desktop"

    local tmp_extract
    tmp_extract=$(mktemp -d)

    if ! (cd "$tmp_extract" && "$appimage_file" --appimage-extract &>/dev/null); then
        echo "  ✗ Failed to extract AppImage contents for $app_name"
        rm -rf "$tmp_extract"
        return 1
    fi

    local squashfs_root="$tmp_extract/squashfs-root"

    # Find the embedded .desktop file (usually at root)
    local embedded_desktop
    embedded_desktop=$(find -L "$squashfs_root" -maxdepth 1 -iname "*.desktop" | head -n 1)
    [[ -z "$embedded_desktop" ]] && embedded_desktop=$(find "$squashfs_root" -maxdepth 3 -iname "*.desktop" | head -n 1)

    # Extract icon if not already present. Tiers in priority order: root
    # level only, the standard icon-theme location, then anywhere in the
    # AppImage as a last resort — each "dir:maxdepth" (empty maxdepth
    # means unlimited depth), stopping at the first hit.
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

for json_file in "$JSON_DIR"/*.appimage.json; do
    [[ -f "$json_file" ]] || continue
    app_name=$(basename "$json_file")
    app_name="${app_name%.appimage.json}"

    appimage_file=$(find "$APPIMAGES_DIR" -maxdepth 1 -iname "${app_name}.appimage" -type f | head -n 1)

    if [[ -z "$appimage_file" ]]; then
        echo "⚠ $app_name: no AppImage found, skipping"
        continue
    fi

    json_field() { jq -r "$1" "$json_file"; }

    manager=$(json_field '.manager')
    current_version=$(json_field '.current_version // empty')
    remote_length=""
    remote_modified=""

    case "$manager" in
        github)
            repo=$(json_field '.repo')
            pattern=$(json_field '.repo_filename')
            allow_pre=$(json_field '.allow_prereleases // false')

            api_url="https://api.github.com/repos/$repo/releases"
            [[ "$allow_pre" == "false" ]] && api_url="$api_url/latest"

            release_json=$(curl -s "$api_url")
            #echo "DEBUG ($app_name): $release_json" >&2
            latest_tag=$(jq -r 'if type=="array" then .[0].tag_name else .tag_name end' <<<"$release_json")
            asset_url=$(jq -r --arg pat "$pattern" '
                (if type=="array" then .[0] else . end).assets[]
                | select(.name | test($pat | gsub("\\*"; ".*")))
                | .browser_download_url' <<<"$release_json" | head -n 1)
            asset_name=$(basename "$asset_url")
            ;;
        gitlab)
            repo_url=$(json_field '.repo_url')
            pattern=$(json_field '.repo_filename')
            project_path="${repo_url#https://gitlab.com/}"
            encoded_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$project_path")

            release_json=$(curl -s "https://gitlab.com/api/v4/projects/$encoded_path/releases")
            latest_tag=$(jq -r '.[0].tag_name' <<<"$release_json")
            asset_url=$(jq -r --arg pat "$pattern" '
                .[0].assets.links[]
                | select(.name | test($pat | gsub("\\*"; ".*")))
                | .direct_asset_url' <<<"$release_json" | head -n 1)
            asset_name=$(basename "$asset_url")
            ;;
        jsonfeed)
            feed_url=$(json_field '.feed_url')
            channel=$(json_field '.channel')
            arch_key=$(json_field '.arch_key')
            download_base=$(json_field '.download_base')

            feed_json=$(curl -s "$feed_url")

            latest_tag=$(jq -r --arg ch "$channel" '.[$ch][0].version' <<<"$feed_json")

            asset_name=$(jq -r --arg ch "$channel" --arg arch "$arch_key" \
                '.[$ch][0].appimage[] | select(.["build-id"] | test($arch)) | .filename' <<<"$feed_json")

            if [[ -z "$asset_name" || "$asset_name" == "null" ]]; then
                echo "⚠ $app_name: could not find AppImage asset for arch $arch_key"
                continue
            fi

            # Derive the minor version (e.g. 3.2.4 -> 3.2) for the download path template
            [[ "$latest_tag" =~ ^([0-9]+\.[0-9]+) ]]
            minor_version="${BASH_REMATCH[1]}"

            asset_url=$(sed \
                -e "s|{minor_version}|$minor_version|" \
                -e "s|{filename}|$asset_name|" <<<"$download_base")
            ;;
        static)
            url=$(json_field '.url')
            stored_length=$(json_field '.content_length // empty')
            stored_modified=$(json_field '.last_modified // empty')

            headers=$(curl -sIL "$url")
            remote_length=$(grep -i "content-length" <<<"$headers" | tail -n 1 | tr -d '\r' | awk '{print $2}')
            remote_modified=$(grep -i "last-modified" <<<"$headers" | tail -n 1 | cut -d' ' -f2- | tr -d '\r')

            if [[ -n "$remote_length" && "$remote_length" == "$stored_length" && "$remote_modified" == "$stored_modified" ]]; then
                echo "✓ $app_name is up to date (unchanged)"
                generate_desktop_entry "$app_name" "$appimage_file"
                continue
            fi

            latest_tag="static-$remote_length"

            # $url can be a redirect landing page with no real filename in
            # its own path (e.g. mudlet.org/download/74/ redirects to
            # .../Mudlet-5.0.1-linux-x64.AppImage.tar) — basename of $url
            # itself would just be "74", so extract_archive's extension
            # match below would never fire. Resolve where it actually
            # lands first and use that for both the download and the name.
            asset_url=$(curl -sIL -o /dev/null -w '%{url_effective}' "$url")
            [[ -z "$asset_url" ]] && asset_url="$url"
            asset_name=$(basename "$asset_url")
            ;;
        *)
            echo "⚠ $app_name: unknown manager '$manager', skipping"
            continue
            ;;
    esac

    if [[ "$manager" != "static" && "$latest_tag" == "$current_version" ]]; then
        echo "✓ $app_name is up to date ($current_version)"
        generate_desktop_entry "$app_name" "$appimage_file"
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

    # Determine if downloaded file is an archive or a direct AppImage.
    # new_appimage defaults to the raw download; the archive case swaps it
    # for the extracted .AppImage before the shared install step below.
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

            new_appimage=$(find "$tmp_extract_dir" -iname "*.appimage" -type f | head -n 1)

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

    # Update stored version/metadata
    tmp_json=$(mktemp)
    if [[ "$manager" == "static" ]]; then
        jq --arg v "$latest_tag" --arg len "$remote_length" --arg mod "$remote_modified" \
            '.current_version = $v | .content_length = $len | .last_modified = $mod' \
            "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
    else
        jq --arg v "$latest_tag" '.current_version = $v' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"
    fi

    echo "  ✓ $app_name updated to $latest_tag"
done
