# shellcheck shell=bash disable=SC2154
# files.sh: archives, checksums, setting the old version aside, and choosing the install name. Loaded by load.sh.
# Cfg keys (manager, url, ...) are set by load_cfg through printf -v, and the
# per-item variables by process_item, so shellcheck can't see them assigned here.

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

hash_file() {
    local sum
    read -r sum _ < <("${1}sum" "$2" 2>/dev/null)
    printf '%s\n' "${sum:-}"
}

# ---------------------------------------------------------------------------
# The old version during an install: renamed into TMP_DIR (always ROOT/.tmp, on
# the same disk) right before the new one goes in, deleted once it's in place,
# renamed back if the install fails or the run is interrupted. It keeps its
# path below the root and gets a .previous suffix, which never ends in .iso, so
# Ventoy can't list it.
# ---------------------------------------------------------------------------
ASIDE=()

previous_path() {
    printf '%s\n' "$TMP_DIR/${1#"${TMP_DIR%/*}/"}.previous"
}

# Moves each existing FILE aside (empty and missing ones are skipped). On a
# failure, puts back what it moved and returns 1.
set_aside() {
    local f p seen
    ASIDE=()
    for f in "$@"; do
        [[ -n "$f" && -e "$f" ]] || continue
        # the installed file is often the target too
        for seen in "${ASIDE[@]}"; do [[ "$seen" == "$f" ]] && continue 2; done
        p=$(previous_path "$f")
        if ! { mkdir -p "${p%/*}" && mv -f "$f" "$p"; }; then
            prune_previous "$p"
            restore_previous
            return 1
        fi
        ASIDE+=("$f")
    done
    return 0
}

# Removes the folders previous_path made for $1, up to TMP_DIR, once empty.
prune_previous() {
    local d="${1%/*}"
    while [[ "$d" == "$TMP_DIR"/* ]] && rmdir "$d" 2>/dev/null; do d="${d%/*}"; done
}

restore_previous() {
    local f p
    for f in "${ASIDE[@]}"; do
        p=$(previous_path "$f")
        mv -f "$p" "$f" && prune_previous "$p"
    done
    ASIDE=()
}

drop_previous() {
    local f p
    for f in "${ASIDE[@]}"; do
        p=$(previous_path "$f")
        rm -f "$p" && prune_previous "$p"
        debug "deleted the old version, ${f##*/}"
    done
    ASIDE=()
}

# After a run that was killed outright: an old version whose file is missing
# goes back; one whose file is there (the new one went in) is deleted.
recover_previous() {
    local p f
    [[ -d "$TMP_DIR" ]] || return 0
    while IFS= read -r -d '' p; do
        f="${TMP_DIR%/*}/${p#"$TMP_DIR/"}"; f="${f%.previous}"
        if [[ -e "$f" ]]; then
            rm -f "$p"
        else
            mv "$p" "$f" && say "⚠ put back ${f##*/}, which an interrupted run had moved aside"
        fi
        prune_previous "$p"
    done < <(find "$TMP_DIR" -type f -name '*.previous' -print0)
}

# Sets new_name, the name to install under: CANDIDATE (the upstream name, versions
# and casing included) if it ends in .ITEM_EXT (any case), so the desktop,
# Archipelago or Ventoy recognises it; otherwise the installed file's name, or on a
# first install the cfg's name with the extension. Sets a variable rather than
# printing, so its debug line isn't captured by $(...).
pick_name() {
    local ext
    case "$ITEM_TYPE" in
        app) ext="AppImage" ;;
        *)   ext="$ITEM_EXT" ;;
    esac
    new_name="$1"
    [[ "${new_name,,}" == *".${ITEM_EXT,,}" ]] && return 0
    if [[ -n "$installed_path" ]]; then
        new_name="${installed_path##*/}"
    else
        new_name="$name.$ext"
    fi
    debug "upstream name '$1' doesn't end in .$ext; installing as $new_name"
}
