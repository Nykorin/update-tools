# shellcheck shell=bash disable=SC2154
# main.sh: what the commands run. update_tools parses the flags and runs each
# mode in its own subshell (run_mode), which loads that mode's module
# (appimages.sh, apworlds.sh or isos.sh: prepare_dir and the hooks) and walks
# its cfgs with the one process_item. A subshell per mode keeps one mode's
# variables, traps and failures out of the next one when update-tools runs
# all three.
# SC2154: cfg keys and manager results are assigned outside this file.

# Each mode's settings, by ITEM_TYPE: ITEM_CMD (the command for it), ITEM_TITLE (its
# heading when update-tools runs all three),
# ITEM_EXT (its files' extension), ITEM_MODE (for installed files;
# empty leaves the mode alone), DEFAULT_DIR (from the settings file; empty when it
# isn't set there) and DIR_KEY (its key in that file), and for the
# folder-not-found error NOT_FOUND_HINT (may be empty) and ROOT_HINT (the -r
# advice, left out under update-tools, which refuses -r).
# shellcheck disable=SC2034  # used by the modules and the shared libraries
item_settings() {
    load_settings
    case "$ITEM_TYPE" in
        app)
            ITEM_CMD="update-tools -m app"
            ITEM_TITLE="AppImages"
            ITEM_EXT="appimage"
            ITEM_MODE="755"
            DIR_KEY="app_dir"
            DEFAULT_DIR="${app_dir:-$HOME/AppImages}"
            NOT_FOUND_HINT=""
            ROOT_HINT="Point to the AppImages folder with -r DIR."
            ;;

        apw)
            ITEM_CMD="update-tools -m apw"
            ITEM_TITLE="Archipelago worlds"
            ITEM_EXT="apworld"
            ITEM_MODE="644"
            DIR_KEY="apw_dir"
            DEFAULT_DIR="${apw_dir:-}"
            NOT_FOUND_HINT="Is the games drive mounted?"
            ROOT_HINT="Point to the folder with -r DIR."
            ;;

        iso)
            ITEM_CMD="update-tools -m iso"
            ITEM_TITLE="ISOs"
            ITEM_EXT="iso"
            # exFAT has no modes
            ITEM_MODE=""
            DIR_KEY="iso_dir"
            DEFAULT_DIR="${iso_dir:-}"
            NOT_FOUND_HINT="Is the Ventoy drive mounted?"
            ROOT_HINT="Point to it with -r DIR."
            ;;

        *)
            echo "ERROR: unknown updater type '$ITEM_TYPE'" >&2
            exit 1
            ;;
    esac
}

# The mode's own code. One source line per module so shellcheck can follow it.
load_module() {
    case "$ITEM_TYPE" in
        app)
            # shellcheck source=lib/appimages.sh
            source "$LIB_DIR/appimages.sh" ;;
        apw)
            # shellcheck source=lib/apworlds.sh
            source "$LIB_DIR/apworlds.sh" ;;
        iso)
            # shellcheck source=lib/isos.sh
            source "$LIB_DIR/isos.sh" ;;
    esac
}

# The "up to date" result, the same for every mode: the version, then the cfg
# saved (not with -c, which writes nothing). AppImages also get their desktop
# entry: rebuilt with its icon re-extracted under -f, like an update would,
# otherwise only recreated if it's missing.
report_up_to_date() {
    if [[ "$check_only" != true ]]; then
        save_update_metadata "$cfg_file"
        case "$ITEM_TYPE" in
            app)
                if [[ "$force" == true ]]; then
                    generate_desktop_entry "$name" "$installed_path"
                else
                    ensure_desktop_entry "$name" "$installed_path"
                fi
                ;;
        esac
    fi
    # the result line last, as after an update
    status_final "✓ up to date (${latest_tag:-$installed_file})"
    ITEM_OUTCOME=current
}

# Walks every cfg; a function of its own so -d can time the whole run. Each
# item's ITEM_OUTCOME (set by process_item when it ends well) is tallied for the
# summary; an item that ends without one has said why it was skipped or failed.
run_items() {
    local rc updated=0 installed=0 current=0 recent=0 unchecked=0
    local -a available=() problems=()
    for i in "${!cfg_files[@]}"; do
        commit_final
        ITEM_OUTCOME=""
        timed "" process_item "$i"; rc=$?
        case "$ITEM_OUTCOME" in
            updated)   (( ++updated )) ;;
            installed) (( ++installed )) ;;
            current)   (( ++current )) ;;
            recent)    (( ++recent )) ;;
            available)
                available+=("$name")
                # the menu's list of updates to download
                [[ -n "${AVAILABLE_FILE:-}" ]] &&
                    printf '%s\t%s\t%s\n' "$ITEM_TYPE" "$name" "$ITEM_SHOWN" >> "$AVAILABLE_FILE"
                ;;
            *)         problems+=("$name") ;;
        esac
        if (( rc == 2 )); then
            unchecked=$(( ${#cfg_files[@]} - i - 1 ))
            break
        fi
    done
    commit_final
    report_summary
    return 0
}

# The mode's summary, after its last item: what went well in one line, then the
# items that need a look, by name, so a long run's failures can't hide in the
# scrollback. Reads run_items' tallies.
report_summary() {
    local line word
    local -a parts=()
    (( updated ))   && parts+=("$updated updated")
    (( installed )) && parts+=("$installed installed")
    (( current ))   && parts+=("$current up to date")
    (( recent ))    && parts+=("$recent checked recently")
    if (( ${#parts[@]} )); then
        printf -v line '%s, ' "${parts[@]}"
        say "✓ ${line%, }"
    fi
    if (( ${#available[@]} )); then
        printf -v line '%s, ' "${available[@]}"
        word=updates; (( ${#available[@]} == 1 )) && word=update
        say "⬆ ${#available[@]} $word available: ${line%, }"
    fi
    if (( ${#problems[@]} )); then
        printf -v line '%s, ' "${problems[@]}"
        say "⚠ ${#problems[@]} skipped or failed: ${line%, }"
    fi
    (( unchecked )) && say "⚠ $unchecked not checked"
    return 0
}

# Hooks a module may define, for the steps where the modes really differ; these
# defaults do nothing (item_stage: AppImages' staging). A hook that returns 1
# has said why and skips the item. ITEM_LOCALS names the variables a module's
# hooks share, made local to each item.
ITEM_LOCALS=()
item_setup()         { :; }   # after load_item (ISOs: "folder" and checksum)
item_prepare_check() { :; }   # before is_up_to_date (ISOs: fetch the checksum)
item_preflight()     { :; }   # before downloading (ISOs: free space)
# the staged download: next to the items (same disk, not RAM-backed /tmp), so
# installing is a rename; the asset's name keeps an archive's extension
item_stage()         { tmp_download="$TMP_DIR/download-$asset_name"; }
item_validate()      { :; }   # after downloading; may set new_file and candidate
item_extras()        { :; }   # after installing (AppImages: desktop entry; ISOs: checksum file)

# One cfg: check it, and update it if needed. The same steps for every mode,
# with the module's hooks where they differ. Returns 2 to stop the whole run.
process_item() {
    local i="$1"
    local rc new_file new_name candidate target CHECKED_AGO
    (( ${#ITEM_LOCALS[@]} )) && local "${ITEM_LOCALS[@]}"
    cfg_file="${cfg_files[$i]}"
    name="${cfg_file##*/}"
    name="${name%.json}"

    PROGRESS_DONE=$i
    PROGRESS_LABEL="$name"
    STATUS=""
    block_redraw

    load_item "$cfg_file" || return 0
    debug "cfg: manager=${manager:-?} version=${current_version:-none} installed_file=${installed_file:-none} last_checked=${last_checked:-never}"
    item_setup || return 0

    installed_path=$(find_installed "$dir")
    if [[ -n "$installed_path" ]]; then
        debug "installed file: ${installed_path##*/}"
    else
        debug "not installed yet: installing it"
    fi

    # skip_checked and skip_hours in the settings file: once per 24 hours by default
    if [[ "$force" == false && -n "$installed_path" ]] && checked_recently; then
        status_final "✓ already checked $CHECKED_AGO ago (${current_version:-$installed_file})"
        ITEM_OUTCOME=recent
        case "$ITEM_TYPE" in
            app) [[ "$check_only" == true ]] || ensure_desktop_entry "$name" "$installed_path" ;;
        esac
        return 0
    fi

    # a 304 has no download URL, so ask for the full list when installing; -f
    # always does (a static item's etag is the file's ETag, still needed)
    if [[ "${manager:-}" == github && ( "$force" == true || -z "$installed_path" ) ]]; then
        etag=""
        if [[ -n "$installed_path" ]]; then
            debug "full release list requested (-f)"
        else
            debug "full release list requested (not installed yet)"
        fi
    fi
    resolve_latest_asset; rc=$?
    if (( rc == 2 )); then
        # every further GitHub request would fail the same way
        say "  ✗ stopping, $(( ${#cfg_files[@]} - i - 1 )) more $ITEM_EXT(s) not checked"
        return 2
    elif (( rc )); then
        return 0
    fi

    # nothing newer on the server, but the installed file is gone
    if (( remote_unchanged )) && [[ -z "$installed_path" ]]; then
        say "⚠ $name: ${installed_file:-its file} is missing and the server has nothing newer, skipping"
        return 0
    fi
    # nothing newer (an old ISO's checksum file may be gone with it)
    if (( remote_unchanged )); then
        report_up_to_date
        return 0
    fi
    item_prepare_check || return 0
    if [[ -n "$installed_path" ]] && is_up_to_date "$installed_path"; then
        report_up_to_date
        return 0
    fi

    # -c: report it, download and write nothing
    if [[ "$check_only" == true ]]; then
        ITEM_SHOWN=$(shown_version "$asset_name")
        status_final "⬆ update available: $ITEM_SHOWN"
        ITEM_OUTCOME=available
        return 0
    fi

    item_preflight || return 0

    if [[ -n "$installed_path" ]]; then
        status "⬆ updating"
    else
        status "⬇ installing"
    fi

    item_stage

    curl_takeover
    # curl -f: an HTTP error page must never replace a working item
    if ! curl_run -fL "${CURL_DL[@]}" --progress-bar "$asset_url" -o "$tmp_download"; then
        curl_abandon
        say "  ✗ Failed to download update for $name"
        rm -f "$tmp_download"
        return 0
    fi
    curl_handback
    debug "downloaded to $tmp_download"

    new_file="" candidate=""
    if ! item_validate; then
        rm -f "$tmp_download"
        rm -rf "$tmp_extract_dir"
        return 0
    fi
    # unless the hook chose otherwise: the download, under its upstream name
    new_file="${new_file:-$tmp_download}"
    candidate="${candidate:-$asset_name}"

    pick_name "$candidate"
    target="$dir/$new_name"

    # the installed version (and a stray file already using the new name) waits
    # in tmp/ until the new one is in place
    if ! set_aside "$installed_path" "$target"; then
        say "  ✗ $name: could not move the old version aside, nothing changed"
        rm -f "$tmp_download"
        rm -rf "$tmp_extract_dir"
        return 0
    fi

    # a rename on one disk; should it still fail, put the old version back
    begin_install "$target"
    if ! mv -f "$new_file" "$target"; then
        restore_previous
        say "  ✗ $name: could not install ${target##*/}, kept the old one"
        rm -f "$tmp_download"
        rm -rf "$tmp_extract_dir"
        return 0
    fi
    [[ -n "$ITEM_MODE" ]] && chmod "$ITEM_MODE" "$target"
    rm -f "$tmp_download"
    rm -rf "$tmp_extract_dir"
    debug "installed as ${target##*/}"
    drop_previous

    item_extras

    installed_file="$new_name"
    save_update_metadata "$cfg_file"
    status_final "✓ updated to $(shown_version "$installed_file")"
    # installed_path is still the old file's, empty on a first install
    ITEM_OUTCOME="${installed_path:+updated}"
    ITEM_OUTCOME="${ITEM_OUTCOME:-installed}"
}

# One mode, app, apw or iso. It runs in a subshell, so its exit 1 (folder or
# command missing) ends only that mode.
# shellcheck disable=SC2034  # its locals are read by the module's process_item
run_mode() {
    ITEM_TYPE="$1"
    item_settings
    load_module || exit 1

    dir="${ROOT_ARG:-$DEFAULT_DIR}"
    dir="${dir%/}"
    if [[ -z "$dir" ]]; then
        [[ "$RUN_TYPE" == "$ITEM_TYPE" ]] || ROOT_HINT=""
        echo "ERROR: no folder set for $ITEM_TITLE: add $DIR_KEY=DIR to $(tilde "$SETTINGS_FILE").${ROOT_HINT:+ $ROOT_HINT}" >&2
        exit 1
    fi
    if [[ ! -d "$dir" ]]; then
        [[ "$RUN_TYPE" == "$ITEM_TYPE" ]] || ROOT_HINT=""
        echo "ERROR: $dir not found.${NOT_FOUND_HINT:+ $NOT_FOUND_HINT}${ROOT_HINT:+ $ROOT_HINT}" >&2
        exit 1
    fi
    # the scripts' own folder in the item folder (dot-prefixed: Archipelago
    # skips it in custom_worlds): db/ holds the cfgs, tmp/ the staged downloads
    # and old versions during an install, on the items' own disk
    ROOT_DIR="$dir"
    CFG_DIR="$dir/.update-tools/db"
    TMP_DIR="$dir/.update-tools/tmp"

    require_cmds "$ITEM_TYPE"
    mkdir -p "$CFG_DIR"
    prepare_dir

    start_run

    shopt -s nullglob
    local cfg_files=("$CFG_DIR"/*.json) f
    # the menu's choice of single items, by name (empty: all of them)
    if [[ -n "${MODE_ITEMS[$ITEM_TYPE]:-}" ]]; then
        local -a chosen=()
        for f in "${cfg_files[@]}"; do
            f="${f##*/}"
            [[ $'\n'"${MODE_ITEMS[$ITEM_TYPE]}"$'\n' == *$'\n'"${f%.json}"$'\n'* ]] && chosen+=("$CFG_DIR/$f")
        done
        cfg_files=("${chosen[@]}")
    fi
    # the layout from before 2026-11-07 isn't read any more
    [[ -d "$dir/.cfg" ]] && say "⚠ $dir/.cfg is ignored: cfgs are NAME.json in .update-tools/db now"
    if (( ${#cfg_files[@]} == 0 )); then
        say "⚠ no *.json files in $CFG_DIR, nothing to do"
        return 0
    fi
    init_progress "${#cfg_files[@]}"

    # the per-item variables all three share; process_item declares the rest
    local i cfg_file name installed_path

    timed "total" run_items

    finish_progress
}

# The menu's choice of single items per mode (newline-separated names), read by
# run_mode; a mode not in it runs all its items.
declare -A MODE_ITEMS=()
# Set by the menu: a heading for every mode, with HEADING_NOTE after the title.
ALWAYS_HEADINGS=0 HEADING_NOTE=""

# Runs each mode in its own subshell, under a ▶ heading when there's more than
# one (or the menu asks for it), carrying on past one that can't run. Returns
# 1 if any couldn't, after a ⚠ skipped: line when there were several.
run_modes() {
    local m list
    local -a skipped=()
    for m in "$@"; do
        ITEM_TYPE="$m"; item_settings
        if (( $# > 1 || ALWAYS_HEADINGS )); then
            printf '%s▶ %s%s%s\n' "$C_BOLD$C_CYAN" "$ITEM_TITLE" "${HEADING_NOTE:+: $HEADING_NOTE}" "$C_R"
        fi
        ( run_mode "$m" ) || skipped+=("$ITEM_TITLE")
    done
    (( ${#skipped[@]} == 0 )) && return 0
    if (( $# > 1 )); then
        printf -v list '%s, ' "${skipped[@]}"
        paint list "⚠ skipped: ${list%, }"
        printf '%s\n' "$list"
    fi
    return 1
}

# The command, update-tools: -m picks the mode (all for all three); without it,
# the menu on a terminal with fzf (menu.sh), else all three. Exits 1 if a mode
# couldn't run.
# shellcheck disable=SC2034  # force, check_only, NOW and checked_at are read by the modes
update_tools() {
    force=false check_only=false
    parse_flags "$@"
    # one time for the whole run: what last_checked saves, and what it's compared with
    printf -v NOW '%(%s)T' -1
    printf -v checked_at '%(%FT%H:%M)T' "$NOW"

    if [[ -z "$RUN_TYPE" ]] && menu_available; then
        run_menu
        exit
    fi
    case "$RUN_TYPE" in
        app|apw|iso) run_modes "$RUN_TYPE" ;;
        *)           run_modes app apw iso ;;
    esac
    exit
}
