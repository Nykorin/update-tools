# shellcheck shell=bash disable=SC2154,SC2034
# appimages.sh: the AppImage updater (archives, desktop entries and icons): its
# prepare_dir, the process_item hooks it needs, and their helpers. main.sh loads
# it for -m app, in that mode's own subshell, so the function names don't clash
# with the other modules. It reads (SC2154) and sets (SC2034) variables that
# main.sh and the shared libraries own.

desktop_entry_path() { echo "$HOME/.local/share/applications/${1}.desktop"; }

# The app's own icons go here. A desktop entry names its icon (Icon=NAME, not a
# path), so the desktop looks it up in the active icon theme and the themes it
# inherits first, and only then in hicolor: an icon pack that has the app wins,
# and these fill in. Only hicolor's own size folders count.
HICOLOR_DIR="$HOME/.local/share/icons/hicolor"
HICOLOR_SIZES=(16 22 24 32 36 48 64 72 96 128 192 256 512)

# Missing, or written before icons moved to the theme (Icon= a path into .icons/).
ensure_desktop_entry() {
    local entry; entry=$(desktop_entry_path "$1")
    if [[ ! -f "$entry" ]] || grep -q "^Icon=$dir/\.icons/" "$entry"; then
        generate_desktop_entry "$1" "$2"
    fi
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

# Installs icon file $1 into hicolor as NAME $2: an SVG in scalable/, a PNG in the
# largest standard size folder that isn't bigger than the PNG (the desktop scales
# it). Anything else is skipped (returns 1).
install_icon() {
    local src="$1" icon="$2" sub size
    local -a b
    if [[ "${src,,}" == *.svg ]] || grep -qs '<svg' "$src"; then
        sub="scalable"
        mkdir -p "$HICOLOR_DIR/$sub/apps"
        cp -L "$src" "$HICOLOR_DIR/$sub/apps/$icon.svg"
        return
    fi
    # a PNG's width is bytes 16-19 of its header
    read -ra b < <(od -An -tu1 -w24 -N24 "$src" 2>/dev/null)
    (( ${#b[@]} == 24 && b[1] == 80 && b[2] == 78 && b[3] == 71 )) || return 1
    local width=$(( b[16] << 24 | b[17] << 16 | b[18] << 8 | b[19] ))
    sub="16x16"
    for size in "${HICOLOR_SIZES[@]}"; do (( width >= size )) && sub="${size}x${size}"; done
    mkdir -p "$HICOLOR_DIR/$sub/apps"
    cp -L "$src" "$HICOLOR_DIR/$sub/apps/$icon.png"
}

# Installs the AppImage's icons under the name its .desktop uses, every time, so an
# update brings a changed icon along. Its own hicolor tree is copied size by size;
# otherwise one icon is taken from the top level (NAME.*, .DirIcon) or, last, from
# anywhere inside. Prints how many files it installed.
install_app_icons() {
    local root="$1" icon="$2" f size n=0
    while IFS= read -r f; do
        size="${f%/apps/*}"; size="${size##*/}"
        case " ${HICOLOR_SIZES[*]/%/x} " in
            *" ${size%x*}x "*) ;;
            *) [[ "$size" == scalable ]] || continue ;;
        esac
        mkdir -p "$HICOLOR_DIR/$size/apps"
        cp -L "$f" "$HICOLOR_DIR/$size/apps/$icon.${f##*.}" && (( n++ ))
    done < <(find -L "$root/usr/share/icons/hicolor" -path "*/apps/*" \( -name "$icon.png" -o -name "$icon.svg" \) 2>/dev/null)
    if (( n == 0 )); then
        local tier icon_dir maxdepth sorted
        for f in "$root/$icon.svg" "$root/$icon.png" "$root/.DirIcon"; do
            [[ -e "$f" ]] && install_icon "$f" "$icon" && { n=1; break; }
        done
        if (( n == 0 )); then
            # tiers, in priority order, as "dir:maxdepth:sorted"
            for tier in "$root:1:" "$root/usr/share/icons::sorted" "$root::"; do
                IFS=: read -r icon_dir maxdepth sorted <<<"$tier"
                f=$(find_icon "$icon_dir" "$maxdepth" "$sorted")
                [[ -n "$f" ]] && install_icon "$f" "$icon" && { n=1; break; }
            done
        fi
    fi
    # GTK reads a cache when the theme has one; a stale cache would hide new icons
    if (( n )) && [[ -f "$HICOLOR_DIR/icon-theme.cache" ]] && command -v gtk-update-icon-cache &>/dev/null; then
        gtk-update-icon-cache -q "$HICOLOR_DIR"
    fi
    printf '%s\n' "$n"
}

generate_desktop_entry() {
    local name="$1" appimage_file="$2"
    local desktop_dest; desktop_dest=$(desktop_entry_path "$name")
    mkdir -p "${desktop_dest%/*}"
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

    # the icon name the app itself uses (an icon pack keys on it); the cfg's name
    # when it has none, or gives a path
    local icon=""
    [[ -n "$embedded_desktop" ]] && icon=$(sed -n 's/^Icon=//p' "$embedded_desktop" | head -n 1)
    [[ -z "$icon" || "$icon" == */* ]] && icon="$name"
    local installed
    installed=$(install_app_icons "$squashfs_root" "$icon")
    if (( installed )); then
        status "🖼 icon installed as $icon"
    else
        say "  ⚠ No icon found for $name"
    fi
    debug "desktop entry icon: $icon ($installed file(s) in $HICOLOR_DIR)"

    if [[ -n "$embedded_desktop" ]]; then
        sed -e "s|^Icon=.*|Icon=$icon|" \
            -e "s|^TryExec=.*|TryExec=$appimage_file|" \
            -e "s|^Exec=.*|Exec=env DESKTOPINTEGRATION=1 $appimage_file %f|" \
            "$embedded_desktop" > "$desktop_dest"
        status "󰴚 desktop entry built from embedded metadata"
    else
        cat > "$desktop_dest" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Icon=$icon
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
            if ! extract_archive "$tmp_download" "$tmp_extract_dir"; then
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
    TMP_DIR="$dir/.tmp"
    # anything left here is from an interrupted earlier run: an old version goes
    # back first, the rest is thrown away
    recover_previous
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
}
