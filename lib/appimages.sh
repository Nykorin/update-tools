# shellcheck shell=bash disable=SC2154,SC2034
# appimages.sh: the AppImage updater (archives, desktop entries and icons): its
# prepare_dir, the process_item hooks it needs, and their helpers. main.sh loads
# it for -m app, in that mode's own subshell, so the function names don't clash
# with the other modules. It reads (SC2154) and sets (SC2034) variables that
# main.sh and the shared libraries own.

desktop_entry_path() { echo "$HOME/.local/share/applications/${1}.desktop"; }

# Writes the entry if it's missing, or if the cfg's desktop_file no longer
# matches it (an edited cfg applies on the next run).
ensure_desktop_entry() {
    local entry; entry=$(desktop_entry_path "$1")
    if [[ ! -f "$entry" ]] ||
       { [[ -n "${desktop_file:-}" ]] && [[ "$(render_desktop_file "$2")" != "$(<"$entry")" ]]; }; then
        generate_desktop_entry "$1" "$2"
    fi
}

# The cfg's desktop_file with {appimage} replaced by $1, quoted on Exec lines
# (which split on spaces).
render_desktop_file() {
    local line file="$1" exec_file="$1"
    [[ "$exec_file" =~ [^A-Za-z0-9._/+-] ]] && exec_file="\"$exec_file\""
    while IFS= read -r line; do
        if [[ "$line" == Exec=* ]]; then
            printf '%s\n' "${line//\{appimage\}/"$exec_file"}"
        else
            printf '%s\n' "${line//\{appimage\}/"$file"}"
        fi
    done <<<"${desktop_file%$'\n'}"
}

icon_exists() {
    find -L "$1" -maxdepth 1 \
        \( -iname "$2.png" -o -iname "$2.svg" -o -iname "$2.xpm" -o -iname "$2.ico" \) \
        -print -quit 2>/dev/null
}

# Removes the icons in $1 named $2, $3, ... (any of the extensions, any case).
remove_icons() {
    local dir="$1" n
    local -a expr=()
    for n in "${@:2}"; do
        expr+=(-o -iname "$n.png" -o -iname "$n.svg" -o -iname "$n.xpm" -o -iname "$n.ico")
    done
    find "$dir" -maxdepth 1 \( "${expr[@]:1}" \) -delete
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

    # desktop_file in the cfg replaces the AppImage's own entry, verbatim
    local own_entry=""
    if [[ -n "${desktop_file:-}" ]]; then
        if [[ $'\n'"$desktop_file" == *$'\n[Desktop Entry]'* ]]; then
            own_entry=1
            debug "desktop entry from the cfg's desktop_file"
        else
            say "  ⚠ $name: desktop_file has no [Desktop Entry] line, using the AppImage's own"
        fi
    fi

    # The entry names its icon instead of pointing at a file, so the icon theme
    # supplies it when it has one. ~/.icons -> .icons/ is the fallback (the icon
    # spec's lookup of unthemed icons, by exact name), so the file is saved
    # under that name too.
    local icon="${icon_name:-}"
    if [[ -z "$icon" && -n "$own_entry" ]]; then
        icon=$(sed -n '/^Icon=/{s///p;q}' <<<"$desktop_file")
    elif [[ -z "$icon" && -n "$embedded_desktop" ]]; then
        icon=$(sed -n '/^Icon=/{s///p;q}' "$embedded_desktop")
    fi
    icon="${icon%.png}"; icon="${icon%.svg}"; icon="${icon%.xpm}"
    # a path instead of a name, or none at all
    [[ -z "$icon" || "$icon" == */* ]] && icon="$name"
    debug "icon name: $icon${icon_name:+ (icon_name)}"

    # Re-extracted every time, so a changed icon in a new release comes along.
    # The old file goes first (it may have another extension or name); an
    # AppImage without an icon leaves whatever is there, such as one added by
    # hand. Tiers, in priority order, as "dir:maxdepth:sorted".
    local icon_src="" tier icon_dir maxdepth sorted
    for tier in "$squashfs_root:1:" "$squashfs_root/usr/share/icons::sorted" "$squashfs_root::"; do
        IFS=: read -r icon_dir maxdepth sorted <<<"$tier"
        icon_src=$(find_icon "$icon_dir" "$maxdepth" "$sorted")
        [[ -n "$icon_src" ]] && break
    done
    local old_icon
    if [[ -n "$icon_src" ]]; then
        remove_icons "$ICONS_DIR" "$name" "$icon"
        cp -L "$icon_src" "$ICONS_DIR/$icon.${icon_src##*.}"
        status "🖼 icon extracted"
    else
        # one added by hand under the cfg name follows the entry's icon name
        old_icon=$(icon_exists "$ICONS_DIR" "$name")
        if [[ -n "$old_icon" && -z "$(icon_exists "$ICONS_DIR" "$icon")" ]]; then
            mv -f "$old_icon" "$ICONS_DIR/$icon.${old_icon##*.}"
        fi
        [[ -z "$(icon_exists "$ICONS_DIR" "$icon")" ]] && say "  ⚠ No icon found for $name"
    fi

    # Exec splits on spaces unless quoted (an install_name may have them)
    local exec_file="$appimage_file" sed_file sed_exec
    [[ "$exec_file" =~ [^A-Za-z0-9._/+-] ]] && exec_file="\"$exec_file\""
    sed_file="${appimage_file//&/\\&}"; sed_file="${sed_file//|/\\|}"
    sed_exec="${exec_file//&/\\&}"; sed_exec="${sed_exec//|/\\|}"
    if [[ -n "$own_entry" ]]; then
        render_desktop_file "$appimage_file" > "$desktop_dest"
        status "󰴚 desktop entry written from desktop_file"
    elif [[ -n "$embedded_desktop" ]]; then
        sed -e "s|^Icon=.*|Icon=$icon|" \
            -e "s|^TryExec=.*|TryExec=$sed_file|" \
            -e "s|^Exec=.*|Exec=env DESKTOPINTEGRATION=1 $sed_exec %f|" \
            "$embedded_desktop" > "$desktop_dest"
        status "󰴚 desktop entry built from embedded metadata"
    else
        cat > "$desktop_dest" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Icon=$icon
TryExec=$appimage_file
Exec=env DESKTOPINTEGRATION=1 $exec_file %f
Categories=Utility;
X-AppImage-Name=$name
EOF
        say "  ⚠ No embedded .desktop found, generated minimal entry for $name"
    fi
    rm -rf "$tmp_extract"
    DESKTOP_TMP=""
}

ITEM_LOCALS=(install_as)

# Optional install_name: the app is installed under that name instead of its
# upstream one ({name} is the cfg name; .AppImage is added when missing). An
# app already installed under another name is renamed now, so the change
# applies without waiting for an update.
item_setup() {
    install_as=""
    [[ -z "${install_name:-}" ]] && return 0
    install_as="${install_name//\{name\}/$name}"
    # a path, or what the desktop entry's Exec line can't take plainly
    if [[ "$install_as" == */* || "$install_as" == . || "$install_as" == .. \
          || "$install_as" == *[\"\`\$\\%]* ]]; then
        say "⚠ $name: install_name must be a file name, not '$install_name', skipping"
        return 1
    fi
    [[ "${install_as,,}" == *.appimage ]] || install_as+=".AppImage"
    debug "install_name: $install_as"

    local old_path; old_path=$(find_installed "$dir")
    [[ -z "$old_path" || "$installed_file" == "$install_as" || "$check_only" == true ]] && return 0
    if [[ -e "$dir/$install_as" ]]; then
        say "⚠ $name: $install_as already exists, not renaming $installed_file"
        return 0
    fi
    if ! mv -f "$old_path" "$dir/$install_as"; then
        say "  ✗ $name: could not rename $installed_file to $install_as"
        return 0
    fi
    say "  ✓ $name: renamed $installed_file to $install_as"
    installed_file="$install_as"
    update_cfg "$cfg_file" "installed_file=$installed_file"
    # the entry's Exec and TryExec name the file
    generate_desktop_entry "$name" "$dir/$install_as"
    return 0
}

# Archived AppImages: extract, then install the AppImage inside (new_file, under
# its own name). A plain AppImage keeps the defaults. install_name replaces
# either name.
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
    [[ -n "$install_as" ]] && candidate="$install_as"
    return 0
}

item_extras() {
    generate_desktop_entry "$name" "$target"
}


prepare_dir() {
    ICONS_DIR="$dir/.icons"
    TMP_DIR="$dir/.tmp"
    mkdir -p "$ICONS_DIR"
    # entries name their icon, and the desktop looks for icons no theme has in
    # ~/.icons, not here
    if [[ "$(readlink -f "$HOME/.icons")" != "$(readlink -f "$ICONS_DIR")" ]]; then
        say "⚠ ~/.icons doesn't lead to $ICONS_DIR, so icons your theme lacks won't show (ln -s '$ICONS_DIR' ~/.icons)"
    fi
    # anything left here is from an interrupted earlier run: an old version goes
    # back first, the rest is thrown away
    recover_previous
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
}
