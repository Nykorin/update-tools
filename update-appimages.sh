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

# Paths to mirror from the real $HOME into every AppImage's portable HOME,
# each relative to $HOME. Add to these as you notice more: theming files
# (GTK, kdeglobals, Kvantum, qt5ct/qt6ct, icon/theme dirs) and shared app
# config that a spawned process creates (Konsole, Dolphin, etc. —
# konsolerc, konsolesshconfig, dolphinrc, ...) both belong here.
# SYMLINK_FILES are individual files; SYMLINK_DIRS are whole directories
# (linked as one unit, so everything inside stays in sync together).
#
# Every entry is checked against the real $HOME before linking, so one
# that doesn't exist there is silently skipped — which also means config
# unique to the AppImage's own app (e.g. .config/Archipelago,
# .local/share/Archipelago) is never touched, since nothing by that name
# exists outside its portable HOME to begin with.
#
# .cache is left alone on purpose — not worth automating; delete it by
# hand from inside an app's portable HOME if it ever grows large.
SYMLINK_FILES=(
    .config/dolphinrc
    .config/kdeglobals         # Plasma color scheme, font, icon theme name
    .config/konsolerc
    .config/konsolesshconfig
    .config/mimeapps.list
    .config/QtProject.conf
    .gtkrc-2.0                 # GTK 2.0 apps read this file directly
    .local/share/recently-used.xbel
    .local/share/user-places.xbel
    .local/share/user-places.xbel.bak
    .local/share/user-places.xbel.tbcache
)

SYMLINK_DIRS=(
    .config/glib-2.0
    .config/gtk-2.0
    .config/gtk-3.0
    .config/gtk-3.0
    .config/gtk-4.0            # also covers libadwaita apps
    .config/Kvantum            # SVG-based Qt theme engine
    .config/pulse
    .config/qt5ct
    .config/qt6ct              # Qt platform-theme picker
    .icons
    .local/share/applications
    .local/share/baloo
    .local/share/color-schemes # referenced by kdeglobals; per-app selectable
    .local/share/dolphin
    .local/share/gegl-0.4
    .local/share/gvfs-metadata
    .local/share/icons
    .local/share/icons         # some installers use these XDG dirs instead
    .local/share/konsole
    .local/share/pki
    .local/share/Steam
    .local/share/themes        # of ~/.icons / ~/.themes (e.g. Orchis-theme)
    .local/share/Trash
    .pki
    .themes
    .var
    .nv
    .net
    .triton
)

# Symlinks each path in "$@" (relative to $HOME) into $app_home, skipping
# any that don't exist as a file/dir on the real $HOME. Called once for
# SYMLINK_FILES and once for SYMLINK_DIRS — see below.
symlink_files() {
    local app_home="$1"; shift
    local path

    for path in "$@"; do
        if [[ -f "$HOME/$path" ]]; then
            mkdir -p "$app_home/$(dirname -- "$path")"
            ln -sf "$HOME/$path" "$app_home/$path"
        fi
    done
}

symlink_dirs() {
    local app_home="$1"; shift
    local path

    for path in "$@"; do
        if [[ -d "$HOME/$path" ]]; then
            mkdir -p "$app_home/$(dirname -- "$path")"
            ln -sfn "$HOME/$path" "$app_home/$path"
        fi
    done
}

icon_exists() {
    local dir="$1" name="$2"
    find -L "$dir" -maxdepth 1 \( -iname "${name}.png" -o -iname "${name}.svg" -o -iname "${name}.xpm" -o -iname "${name}.ico" \) 2>/dev/null | head -n 1
}

generate_desktop_entry() {
    local app_dir="$1" app_name="$2" appimage_file="$3"
    local wrapper_script="$app_dir${app_name}.appimage.sh"

    local icon_dest="$app_dir/$app_name"
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

    # Extract icon if not already present — prefer root-level icons first
    if [[ -z "$(icon_exists "$app_dir" "$app_name")" ]]; then
        local icon_src
        icon_src=$(find "$squashfs_root" -maxdepth 1 \( -iname "*.png" -o -iname "*.svg" \) | head -n 1)

        # Fall back to standard icon theme location
        if [[ -z "$icon_src" ]]; then
            icon_src=$(find -L "$squashfs_root/usr/share/icons" \( -iname "*.png" -o -iname "*.svg" \) 2>/dev/null | sort -r | head -n 1)
        fi

        # Last resort: search everywhere
        if [[ -z "$icon_src" ]]; then
            icon_src=$(find -L "$squashfs_root" \( -iname "*.png" -o -iname "*.svg" \) | head -n 1)
        fi

        if [[ -n "$icon_src" ]]; then
            cp "$icon_src" "${icon_dest}.${icon_src##*.}"
            echo "  🖼 Extracted icon for $app_name"
        else
            echo "  ⚠ No icon found for $app_name"
        fi
    fi

    local icon_path
    icon_path=$(icon_exists "$app_dir" "$app_name")

    if [[ -n "$embedded_desktop" ]]; then
        sed \
            -e "s|^Icon=.*|Icon=${icon_path:-}|" \
            -e "s|^TryExec=.*|TryExec=$wrapper_script|" \
            -e "s|^Exec=.*|Exec=env DESKTOPINTEGRATION=1 $wrapper_script %f|" \
            "$embedded_desktop" > "$desktop_dest"

        echo "  ✓ Desktop entry built from embedded metadata for $app_name"
    else
        cat > "$desktop_dest" <<EOF
[Desktop Entry]
Type=Application
Name=$app_name
Icon=${icon_path:-}
TryExec=$appimage_file
Exec=env DESKTOPINTEGRATION=1 $wrapper_script
Categories=Utility;
X-AppImage-Name=$app_name
EOF
        echo "  ⚠ No embedded .desktop found, generated minimal entry for $app_name"
    fi

    rm -rf "$tmp_extract"
}

for app_dir in "$APPIMAGES_DIR"/*/; do
    [[ -d "$app_dir" ]] || continue
    app_name=$(basename "$app_dir")

    appimage_file=$(find "$app_dir" -maxdepth 1 -iname "*.appimage" -type f | head -n 1)
    json_file=$(find "$app_dir" -maxdepth 1 -iname "*.appimage.json" -type f | head -n 1)

    if [[ -z "$appimage_file" ]]; then
        echo "⚠ $app_name: no AppImage found, skipping"
        continue
    fi

    if [[ -z "$json_file" ]]; then
        echo "⚠ $app_name: no update metadata found, skipping"
        continue
    fi

    # Refresh theming symlinks into this app's portable HOME on every run,
    # independent of whether an update is available — app_dir already ends
    # in / (from the glob above), so no separator is added here.
    app_home="${app_dir}${app_name}.appimage.home"
    symlink_files "$app_home" "${SYMLINK_FILES[@]}"
    symlink_dirs "$app_home" "${SYMLINK_DIRS[@]}"

    manager=$(jq -r '.manager' "$json_file")
    current_version=$(jq -r '.current_version // empty' "$json_file")
    remote_length=""
    remote_modified=""

    case "$manager" in
        github)
            repo=$(jq -r '.repo' "$json_file")
            pattern=$(jq -r '.repo_filename' "$json_file")
            allow_pre=$(jq -r '.allow_prereleases // false' "$json_file")

            api_url="https://api.github.com/repos/$repo/releases"
            [[ "$allow_pre" == "false" ]] && api_url="$api_url/latest"

            release_json=$(curl -s "$api_url")
            #echo "DEBUG ($app_name): $release_json" >&2
            latest_tag=$(echo "$release_json" | jq -r 'if type=="array" then .[0].tag_name else .tag_name end')
            asset_url=$(echo "$release_json" | jq -r --arg pat "$pattern" '
                (if type=="array" then .[0] else . end).assets[]
                | select(.name | test($pat | gsub("\\*"; ".*")))
                | .browser_download_url' | head -n 1)
            asset_name=$(basename "$asset_url")
            ;;
        gitlab)
            repo_url=$(jq -r '.repo_url' "$json_file")
            pattern=$(jq -r '.repo_filename' "$json_file")
            project_path=$(echo "$repo_url" | sed -E 's#https://gitlab.com/##')
            encoded_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$project_path")

            release_json=$(curl -s "https://gitlab.com/api/v4/projects/$encoded_path/releases")
            latest_tag=$(echo "$release_json" | jq -r '.[0].tag_name')
            asset_url=$(echo "$release_json" | jq -r --arg pat "$pattern" '
                .[0].assets.links[]
                | select(.name | test($pat | gsub("\\*"; ".*")))
                | .direct_asset_url' | head -n 1)
            asset_name=$(basename "$asset_url")
            ;;
        jsonfeed)
            feed_url=$(jq -r '.feed_url' "$json_file")
            channel=$(jq -r '.channel' "$json_file")
            arch_key=$(jq -r '.arch_key' "$json_file")
            download_base=$(jq -r '.download_base' "$json_file")

            feed_json=$(curl -s "$feed_url")

            latest_tag=$(echo "$feed_json" | jq -r --arg ch "$channel" '.[$ch][0].version')

            asset_name=$(echo "$feed_json" | jq -r --arg ch "$channel" --arg arch "$arch_key" \
                '.[$ch][0].appimage[] | select(.["build-id"] | test($arch)) | .filename')

            if [[ -z "$asset_name" || "$asset_name" == "null" ]]; then
                echo "⚠ $app_name: could not find AppImage asset for arch $arch_key"
                continue
            fi

            # Derive the minor version (e.g. 3.2.4 -> 3.2) for the download path template
            minor_version=$(echo "$latest_tag" | grep -oE '^[0-9]+\.[0-9]+')

            asset_url=$(echo "$download_base" | sed \
                -e "s|{minor_version}|$minor_version|" \
                -e "s|{filename}|$asset_name|")
            ;;
        static)
            url=$(jq -r '.url' "$json_file")
            stored_length=$(jq -r '.content_length // empty' "$json_file")
            stored_modified=$(jq -r '.last_modified // empty' "$json_file")

            headers=$(curl -sIL "$url")
            remote_length=$(echo "$headers" | grep -i "content-length" | tail -n 1 | tr -d '\r' | awk '{print $2}')
            remote_modified=$(echo "$headers" | grep -i "last-modified" | tail -n 1 | cut -d' ' -f2- | tr -d '\r')

            if [[ -n "$remote_length" && "$remote_length" == "$stored_length" && "$remote_modified" == "$stored_modified" ]]; then
                echo "✓ $app_name is up to date (unchanged)"
                generate_desktop_entry "$app_dir" "$app_name" "$appimage_file"
                continue
            fi

            latest_tag="static-$remote_length"
            asset_url="$url"
            asset_name=$(basename "$url")
            ;;
        *)
            echo "⚠ $app_name: unknown manager '$manager', skipping"
            continue
            ;;
    esac

    if [[ "$manager" != "static" && "$latest_tag" == "$current_version" ]]; then
        echo "✓ $app_name is up to date ($current_version)"
        generate_desktop_entry "$app_dir" "$app_name" "$appimage_file"
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

    # Determine if downloaded file is an archive or a direct AppImage
    case "$asset_name" in
        *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar|*.zip)
            tmp_extract_dir=$(mktemp -d)
            if ! extract_archive "$tmp_download" "$tmp_extract_dir"; then
                echo "  ✗ Failed to extract archive for $app_name"
                rm -f "$tmp_download"
                rm -rf "$tmp_extract_dir"
                continue
            fi

            extracted_appimage=$(find "$tmp_extract_dir" -iname "*.appimage" -type f | head -n 1)

            if [[ -z "$extracted_appimage" ]]; then
                echo "  ✗ No AppImage found inside extracted archive for $app_name"
                rm -f "$tmp_download"
                rm -rf "$tmp_extract_dir"
                continue
            fi

            mv "$appimage_file" "${appimage_file}.bak"
            mv "$extracted_appimage" "$appimage_file"
            chmod +x "$appimage_file"

            rm -f "$tmp_download"
            rm -rf "$tmp_extract_dir"
            ;;
        *)
            mv "$appimage_file" "${appimage_file}.bak"
            mv "$tmp_download" "$appimage_file"
            chmod +x "$appimage_file"
            ;;
    esac

    generate_desktop_entry "$app_dir" "$app_name" "$appimage_file"

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
