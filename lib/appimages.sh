# shellcheck shell=bash disable=SC2154,SC2034
# appimages.sh: the AppImage updater (archives, desktop entries and icons): its
# prepare_dir, the process_item hooks it needs, and their helpers. main.sh loads
# it for -m app, in that mode's own subshell, so the function names don't clash
# with the other modules. It reads (SC2154) and sets (SC2034) variables that
# main.sh and the shared libraries own.

desktop_entry_path() { echo "$HOME/.local/share/applications/${1}.desktop"; }

ensure_desktop_entry() {
    [[ -f "$(desktop_entry_path "$1")" ]] || generate_desktop_entry "$1" "$2"
}

icon_exists() {
    find -L "$1" -maxdepth 1 \
        \( -iname "$2.png" -o -iname "$2.svg" -o -iname "$2.xpm" -o -iname "$2.ico" \) \
        -print -quit 2>/dev/null
}

# $1 dir, $2 maxdepth (empty = unlimited), $3 non-empty = pick by version sort
# (scalable first, else the largest size). Needed for icon-theme trees, where
# find's own order is arbitrary and could hand back a 16x16 icon.
find_icon() {
    local -a args=(-L "$1")
    [[ -n "$2" ]] && args+=(-maxdepth "$2")
    args+=(\( -iname "*.png" -o -iname "*.svg" \))
    if [[ -n "${3:-}" ]]; then
        find "${args[@]}" 2>/dev/null | sort -rV | head -n 1
    else
        find "${args[@]}" -print -quit 2>/dev/null
    fi
}

generate_desktop_entry() {
    local name="$1" appimage_file="$2"
    local icon_dest="$ICONS_DIR/$name"
    local desktop_dest; desktop_dest=$(desktop_entry_path "$name")
    mkdir -p "$ICONS_DIR" "${desktop_dest%/*}"
    local tmp_extract="$TMP_DIR/desktop"
    rm -rf "$tmp_extract"
    mkdir -p "$tmp_extract"
    DESKTOP_TMP="$tmp_extract"

    if ! (cd "$tmp_extract" && "$appimage_file" --appimage-extract &>/dev/null); then
        say "  ✗ Failed to extract AppImage contents for $name"
        rm -rf "$tmp_extract"; DESKTOP_TMP=""; return 1
    fi

    local squashfs_root="$tmp_extract/squashfs-root"
    local embedded_desktop
    embedded_desktop=$(find -L "$squashfs_root" -maxdepth 1 -iname "*.desktop" -print -quit)
    [[ -z "$embedded_desktop" ]] && \
        embedded_desktop=$(find "$squashfs_root" -maxdepth 3 -iname "*.desktop" -print -quit)

    # re-extracted every time, so a changed icon in a new release comes along; the
    # old file goes first (it may have another extension). An AppImage without an
    # icon leaves whatever is there, such as one added by hand.
    # tiers, in priority order, as "dir:maxdepth:sorted"
    local icon_src="" tier icon_dir maxdepth sorted
    for tier in "$squashfs_root:1:" "$squashfs_root/usr/share/icons::sorted" "$squashfs_root::"; do
        IFS=: read -r icon_dir maxdepth sorted <<<"$tier"
        icon_src=$(find_icon "$icon_dir" "$maxdepth" "$sorted")
        [[ -n "$icon_src" ]] && break
    done
    if [[ -n "$icon_src" ]]; then
        find "$ICONS_DIR" -maxdepth 1 \( -iname "$name.png" -o -iname "$name.svg" -o -iname "$name.xpm" -o -iname "$name.ico" \) -delete
        cp -L "$icon_src" "${icon_dest}.${icon_src##*.}"
        status "🖼 icon extracted"
    elif [[ -z "$(icon_exists "$ICONS_DIR" "$name")" ]]; then
        say "  ⚠ No icon found for $name"
    fi

    local icon_path; icon_path=$(icon_exists "$ICONS_DIR" "$name")

    if [[ -n "$embedded_desktop" ]]; then
        sed -e "s|^Icon=.*|Icon=${icon_path:-}|" \
            -e "s|^TryExec=.*|TryExec=$appimage_file|" \
            -e "s|^Exec=.*|Exec=env DESKTOPINTEGRATION=1 $appimage_file %f|" \
            "$embedded_desktop" > "$desktop_dest"
        status "󰴚 desktop entry built from embedded metadata"
    else
        cat > "$desktop_dest" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Icon=${icon_path:-}
TryExec=$appimage_file
Exec=env DESKTOPINTEGRATION=1 $appimage_file %f
Categories=Utility;
X-AppImage-Name=$name
EOF
        say "  ⚠ No embedded .desktop found, generated minimal entry for $name"
    fi
    rm -rf "$tmp_extract"
    DESKTOP_TMP=""
}

# Archived AppImages: extract, then install the AppImage inside (new_file, under
# its own name). A plain AppImage keeps the defaults.
item_validate() {
    tmp_extract_dir=""
    case "$asset_name" in
        *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar|*.zip)
            tmp_extract_dir="$TMP_DIR/archive"
            rm -rf "$tmp_extract_dir"
            mkdir -p "$tmp_extract_dir"
            if ! extract "$tmp_download" "$tmp_extract_dir"; then
                say "  ✗ Failed to extract archive for $name"
                return 1
            fi
            new_file=$(find "$tmp_extract_dir" -iname "*.appimage" -type f -print -quit)
            debug "archive holds ${new_file:-no AppImage}"
            if [[ -z "$new_file" ]]; then
                say "  ✗ No AppImage found inside extracted archive for $name"
                return 1
            fi
            candidate="${new_file##*/}"
            ;;
    esac
}

item_extras() {
    generate_desktop_entry "$name" "$target"
}


prepare_dir() {
    ICONS_DIR="$dir/.icons"
    TMP_DIR="$dir/.tmp"
    mkdir -p "$ICONS_DIR"
    # anything left here is from an interrupted earlier run: an old version goes
    # back first, the rest is thrown away
    recover_previous
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
}
