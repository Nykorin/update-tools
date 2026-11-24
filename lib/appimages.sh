# shellcheck shell=bash disable=SC2154,SC2034
# appimages.sh: the AppImage updater (archives, desktop entries and icons): its
# prepare_dir, the process_item hooks it needs, and their helpers. main.sh loads
# it for update-appimages, in that mode's own subshell, so the function names
# don't clash with the other modules. It reads (SC2154) and sets (SC2034)
# variables that main.sh and the shared libraries own.

APPS_DIR="$HOME/.local/share/applications"
desktop_entry_path() { echo "$APPS_DIR/${1}.desktop"; }

# Set when an entry is written or removed, so mode_finish refreshes the
# desktop database once per run.
DESKTOP_DB_DIRTY=0

# The database (mimeinfo.cache) maps MIME types to entries; an entry written by
# an update may list other types than before, so any write counts. A missing
# update-desktop-database (desktop-file-utils) only warns: the entries work
# without it, only "Open with" lags.
mode_finish() {
    (( DESKTOP_DB_DIRTY )) || return 0
    DESKTOP_DB_DIRTY=0
    PROGRESS_LABEL="desktop database"
    if ! command -v update-desktop-database &>/dev/null; then
        say "⚠ update-desktop-database not found (desktop-file-utils), the desktop database wasn't refreshed"
        return 0
    fi
    if update-desktop-database -q "$APPS_DIR" 2>/dev/null; then
        debug "refreshed ($(tilde "$APPS_DIR"))"
    else
        say "⚠ update-desktop-database $(tilde "$APPS_DIR") failed"
    fi
    return 0
}

# Writes the entry if it's missing, or if db/NAME.desktop no longer matches
# it (an edited file applies on the next run).
ensure_desktop_entry() {
    local entry; entry=$(desktop_entry_path "$1")
    if [[ ! -f "$entry" ]] ||
       { [[ -f "$(desktop_sidecar "$1")" ]] && [[ "$(render_desktop_file "$1" "$2")" != "$(<"$entry")" ]]; }; then
        generate_desktop_entry "$1" "$2"
    fi
}

# Your own entry for app $1, used instead of the AppImage's.
desktop_sidecar() { echo "$CFG_DIR/$1.desktop"; }

# db/NAME.desktop for app $1 with {appimage} replaced by $2, quoted on Exec
# lines (which split on spaces).
render_desktop_file() {
    local line file="$2" exec_file="$2"
    [[ "$exec_file" =~ [^A-Za-z0-9._/+-] ]] && exec_file="\"$exec_file\""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" == Exec=* ]]; then
            printf '%s\n' "${line//\{appimage\}/"$exec_file"}"
        else
            printf '%s\n' "${line//\{appimage\}/"$file"}"
        fi
    done < "$(desktop_sidecar "$1")"
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

    # db/NAME.desktop replaces the AppImage's own entry, verbatim
    local own_entry="" sidecar; sidecar=$(desktop_sidecar "$name")
    if [[ -f "$sidecar" ]]; then
        if grep -q '^\[Desktop Entry\][[:space:]]*$' "$sidecar"; then
            own_entry=1
            debug "desktop entry from ${sidecar##*/}"
        else
            say "  ⚠ $name: ${sidecar##*/} has no [Desktop Entry] line, using the AppImage's own"
        fi
    fi

    # The entry names its icon instead of pointing at a file, so the icon theme
    # supplies it when it has one. ~/.icons -> icons/ is the fallback (the icon
    # spec's lookup of unthemed icons, by exact name), so the file is saved
    # under that name too.
    local icon="${icon_name:-}"
    if [[ -z "$icon" && -n "$own_entry" ]]; then
        icon=$(sed -n '/^Icon=/{s///;s/\r$//;p;q}' "$sidecar")
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
    # Written to a temp file and renamed into place, read-only: apps that write
    # their own entry on every start (Beeper, Stability Matrix) open the file to
    # write it, which a read-only file refuses, so the entry stays this one
    # (both apps catch the error). The temp file is hidden and ends in .tmp, so
    # no launcher reads it.
    local entry_tmp="${desktop_dest%/*}/.${desktop_dest##*/}.tmp"
    DESKTOP_ENTRY_TMP="$entry_tmp"
    if [[ -n "$own_entry" ]]; then
        render_desktop_file "$name" "$appimage_file" > "$entry_tmp"
        status "󰴚 desktop entry written from ${sidecar##*/}"
    elif [[ -n "$embedded_desktop" ]]; then
        sed -e "s|^Icon=.*|Icon=$icon|" \
            -e "s|^TryExec=.*|TryExec=$sed_file|" \
            -e "s|^Exec=.*|Exec=env DESKTOPINTEGRATION=1 $sed_exec %f|" \
            "$embedded_desktop" > "$entry_tmp"
        status "󰴚 desktop entry built from embedded metadata"
    else
        cat > "$entry_tmp" <<EOF
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
    if ! { chmod 444 "$entry_tmp" && mv -f "$entry_tmp" "$desktop_dest"; }; then
        say "  ✗ $name: could not write ${desktop_dest##*/}"
        rm -f "$entry_tmp"
    else
        DESKTOP_DB_DIRTY=1
    fi
    DESKTOP_ENTRY_TMP=""
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
    save_state "$cfg_file" "installed_file=$installed_file"
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

# A bare -u: the installed AppImages (cfgs whose installed_file is still
# there) in fzf, several can be marked; prints the chosen cfg names. Esc
# chooses none.
pick_installed() {
    local f name file size
    local -a lines=()
    for f in "$CFG_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"; name="${name%.json}"
        file=$(jq -r '.state.installed_file // empty' "$f" 2>/dev/null)
        [[ -n "$file" && -f "$dir/$file" ]] || continue
        size=$(du -h --apparent-size "$dir/$file" 2>/dev/null); size="${size%%$'\t'*}"
        lines+=("$(printf '%s\t%-28s %-52s %6s' "$name" "$name" "$file" "$size")")
    done
    if (( ${#lines[@]} == 0 )); then
        say "⚠ no installed AppImages in $(tilde "$dir")"
        return 0
    fi
    printf '%s\n' "${lines[@]}" |
        menu_fzf --header="Uninstall which AppImages?  (Tab: mark, Enter: go, Esc: quit)" |
        cut -f1
}

# -u: removes each app named (by its cfg name), or picked (pick_installed): the
# AppImage, its desktop entry, its icon (icons/NAME.* and icons/ICON.*, unless
# another entry names ICON too), then db/NAME.desktop and the cfg, last, so an
# interrupted uninstall can be run again. On a terminal it lists every app's
# files and asks once; -c only lists them. Returns 1 if any app wasn't found
# or wasn't removed in full.
uninstall_items() {
    local name cfg_file entry icon f answer failed=0 shown
    local -a files names=()
    local -A plan=()

    if (( $# == 0 )); then
        if ! menu_available; then
            say "✗ -u without a name needs a terminal and fzf; name the AppImage: -u NAME"
            return 1
        fi
        mapfile -t names < <(pick_installed)
        (( ${#names[@]} )) || return 0
        set -- "${names[@]}"
        names=()
    fi

    # what each app removes, as newline-separated paths
    for name; do
        PROGRESS_LABEL="$name"
        cfg_file="$CFG_DIR/$name.json"
        if [[ ! -f "$cfg_file" ]]; then
            say "✗ $name: no cfg ($(tilde "$cfg_file")), nothing uninstalled"
            failed=1; continue
        fi
        # an unreadable cfg can't say which AppImage is the app's
        if ! load_item "$cfg_file"; then
            failed=1; continue
        fi

        files=()
        f=$(find_installed "$dir"); [[ -n "$f" ]] && files+=("$f")
        [[ -z "${installed_file:-}" || -n "$f" ]] || say "⚠ $name: $installed_file is already gone"
        entry=$(desktop_entry_path "$name")
        # the icon the entry names, as generate_desktop_entry chose it
        icon=""
        if [[ -f "$entry" ]]; then
            files+=("$entry")
            icon=$(sed -n '/^Icon=/{s///;s/\r$//;p;q}' "$entry")
        fi
        icon="${icon:-${icon_name:-$name}}"
        [[ "$icon" == */* ]] && icon="$name"
        # an icon another entry names stays (two apps with one icon_name)
        if [[ "$icon" != "$name" ]] &&
           grep -qlx --exclude="${entry##*/}" "Icon=$icon" "$APPS_DIR"/*.desktop 2>/dev/null; then
            debug "icon $icon kept: another desktop entry names it"
            icon="$name"
        fi
        while IFS= read -r -d '' f; do files+=("$f"); done < <(
            find "$ICONS_DIR" -maxdepth 1 \( \
                -iname "$name.png" -o -iname "$name.svg" -o -iname "$name.xpm" -o -iname "$name.ico" -o \
                -iname "$icon.png" -o -iname "$icon.svg" -o -iname "$icon.xpm" -o -iname "$icon.ico" \
                \) -print0 2>/dev/null)
        f=$(desktop_sidecar "$name"); [[ -f "$f" ]] && files+=("$f")
        files+=("$cfg_file")

        [[ -v "plan[$name]" ]] || names+=("$name")
        printf -v "plan[$name]" '%s\n' "${files[@]}"
    done
    PROGRESS_LABEL=""
    (( ${#names[@]} )) || return "$failed"

    if [[ "$check_only" == true ]]; then
        for name in "${names[@]}"; do
            mapfile -t files <<<"${plan[$name]%$'\n'}"
            printf -v shown '%s, ' "${files[@]##*/}"
            say "$name: would remove ${shown%, }"
        done
        return "$failed"
    fi
    if [[ -t 0 && -t 1 ]]; then
        for name in "${names[@]}"; do
            say "$name: removes"
            while IFS= read -r f; do say "  $(tilde "$f")"; done <<<"${plan[$name]%$'\n'}"
        done
        f="${names[*]}"
        (( ${#names[@]} > 1 )) && f="${#names[@]} AppImages (${f// /, })"
        read -r -p "Uninstall $f? [y/N] " answer
        if [[ "${answer,,}" != y && "${answer,,}" != yes ]]; then
            say "nothing uninstalled"
            return "$failed"
        fi
    fi

    for name in "${names[@]}"; do
        PROGRESS_LABEL="$name"
        cfg_file="$CFG_DIR/$name.json"
        entry=$(desktop_entry_path "$name")
        mapfile -t files <<<"${plan[$name]%$'\n'}"
        printf -v shown '%s, ' "${files[@]##*/}"
        # the cfg last: if anything fails, it's still there for another try
        for f in "${files[@]}"; do
            [[ "$f" == "$cfg_file" ]] && continue
            if ! rm -f "$f"; then
                say "✗ $name: could not remove $(tilde "$f"), kept its cfg"
                failed=1; continue 2
            fi
            [[ "$f" == "$entry" ]] && DESKTOP_DB_DIRTY=1
        done
        if ! rm -f "$cfg_file"; then
            say "✗ $name: could not remove $(tilde "$cfg_file")"
            failed=1; continue
        fi
        say "✓ $name: uninstalled (${shown%, })"
    done
    PROGRESS_LABEL=""
    return "$failed"
}

prepare_dir() {
    ICONS_DIR="$dir/.update-tools/icons"
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
