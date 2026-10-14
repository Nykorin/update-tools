# shellcheck shell=bash disable=SC2154
# main.sh: what update-tools runs. update_tools parses the flags and runs each
# mode in its own subshell (run_mode), which loads that mode's module
# (appimages.sh, apworlds.sh or isos.sh: prepare_dir and the hooks) and walks
# its cfgs with the one process_item. A subshell per mode keeps one mode's variables, traps and failures
# out of the next one under -m all. Variables the managers and cfgs set (SC2154)
# aren't visible to shellcheck here.

# Each mode's settings, by ITEM_TYPE: ITEM_TITLE (its heading under -m all),
# ITEM_EXT (its cfgs are NAME.ITEM_EXT.cfg), ITEM_MODE (for installed files;
# empty leaves the mode alone), DEFAULT_DIR, and NOT_FOUND_HINT (the end of the
# folder-not-found error).
# shellcheck disable=SC2034  # used by the modules and the shared libraries
item_settings() {
    case "$ITEM_TYPE" in
        app)
            ITEM_TITLE="AppImages"
            ITEM_EXT="appimage"
            ITEM_MODE="755"
            DEFAULT_DIR="$HOME/AppImages"
            NOT_FOUND_HINT="Point to the AppImages folder with -r DIR."
            ;;

        apw)
            ITEM_TITLE="Archipelago worlds"
            ITEM_EXT="apworld"
            ITEM_MODE="644"
            DEFAULT_DIR="/mnt/games_rando/Archipelago/custom_worlds"
            NOT_FOUND_HINT="Is the games drive mounted? Point to the folder with -r DIR."
            ;;

        iso)
            ITEM_TITLE="ISOs"
            ITEM_EXT="iso"
            # exFAT has no modes
            ITEM_MODE=""
            DEFAULT_DIR="/mnt/ventoy/_ISO"
            NOT_FOUND_HINT="Is the Ventoy drive mounted? Point to it with -r DIR."
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

# The "up to date" result, the same for every updater: the version, then the cfg
# saved (not with -c, which writes nothing); AppImages also refresh their desktop
# entry.
report_up_to_date() {
    status_final "✓ up to date (${latest_tag:-$installed_file})"
    [[ "$check_only" == true ]] && return 0
    save_update_metadata "$cfg_file"
    case "$ITEM_TYPE" in
        app) ensure_desktop_entry "$name" "$installed_path" ;;
    esac
}

# Walks every cfg; a function of its own so -d can time the whole run.
run_items() {
    for i in "${!cfg_files[@]}"; do
        commit_final
        timed "" process_item "$i" || { (( $? == 2 )) && break; }
    done
    return 0
}

# Hooks a module may define, for the steps where the modes really differ; these
# defaults do nothing (item_stage: AppImages' staging). A hook that returns 1 has
# said why and skips the item. ITEM_LOCALS names the variables a module's hooks
# share, made local to each item.
ITEM_LOCALS=()
item_setup()         { :; }   # after load_cfg (ISOs: folder= and checksum)
item_prepare_check() { :; }   # before is_up_to_date (ISOs: fetch the checksum)
item_preflight()     { :; }   # before downloading (ISOs: free space)
# the staged download: next to the items (same disk, not RAM-backed /tmp), so
# installing is a rename; the asset's name keeps an archive's extension
item_stage()         { tmp_download="$TMP_DIR/download-$asset_name"; }
item_validate()      { :; }   # after downloading; may set new_file and candidate
item_extras()        { :; }   # after installing (AppImages: desktop entry; ISOs: checksum file)

# One cfg: check it, and update it if needed. The same steps for every mode, with
# the module's hooks where they differ. Returns 2 to stop the whole run.
process_item() {
    local i="$1"
    local rc new_file new_name candidate target
    (( ${#ITEM_LOCALS[@]} )) && local "${ITEM_LOCALS[@]}"
    cfg_file="${cfg_files[$i]}"
    name="${cfg_file##*/}"
    name="${name%".$ITEM_EXT.cfg"}"

    PROGRESS_DONE=$i
    PROGRESS_LABEL="$name"
    STATUS=""
    block_redraw

    load_cfg "$cfg_file"
    debug "cfg: manager=${manager:-?} version=${current_version:-none} installed_file=${installed_file:-none} last_checked=${last_checked:-never}"
    item_setup || return 0

    installed_path=$(find_installed "$dir")
    if [[ -n "$installed_path" ]]; then
        debug "installed file: ${installed_path##*/}"
    else
        debug "not installed yet: installing it"
    fi

    if [[ "$force" == false && -n "$installed_path" && "${last_checked:-}" == "$today" ]]; then
        status_final "✓ already checked today (${current_version:-$installed_file})"
        case "$ITEM_TYPE" in
            app) [[ "$check_only" == true ]] || ensure_desktop_entry "$name" "$installed_path" ;;
        esac
        return 0
    fi

    # a 304 has no download URL, so ask for the full list when installing; -f always does
    # (a static item's etag is the server's file ETag, which it still needs to compare)
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

    # nothing newer on the server, but the installed file is gone: nothing to download
    if (( remote_unchanged )) && [[ -z "$installed_path" ]]; then
        say "⚠ $name: ${installed_file:-its file} is missing and the server has nothing newer, skipping"
        return 0
    fi
    # nothing newer on the server (an old ISO's checksum file may be gone with it)
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
        status_final "⬆ update available: $(shown_version "$asset_name")"
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
    # -f: an HTTP error page must never replace a working item
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
    # unless the hook found something else, it's the download under the upstream name
    new_file="${new_file:-$tmp_download}"
    candidate="${candidate:-$asset_name}"

    pick_name "$candidate"
    target="$dir/$new_name"

    # the installed version (and a stray file already using the new name) waits in
    # .tmp until the new one is in place
    if ! set_aside "$installed_path" "$target"; then
        say "  ✗ $name: could not move the old version aside, nothing changed"
        rm -f "$tmp_download"
        rm -rf "$tmp_extract_dir"
        return 0
    fi

    # a rename on one disk; should it still fail, put the old version back
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
    if [[ ! -d "$dir" ]]; then
        echo "ERROR: $dir not found. $NOT_FOUND_HINT" >&2
        exit 1
    fi
    CFG_DIR="$dir/.cfg"

    require_cmds "$ITEM_TYPE"
    mkdir -p "$CFG_DIR"
    prepare_dir

    start_run

    shopt -s nullglob
    local cfg_files=("$CFG_DIR"/*."$ITEM_EXT".cfg)
    if (( ${#cfg_files[@]} == 0 )); then
        say "⚠ no *.$ITEM_EXT.cfg files in $CFG_DIR, nothing to do"
        return 0
    fi
    init_progress "${#cfg_files[@]}"

    # the per-item variables all three share; process_item declares the rest
    local i cfg_file name installed_path

    timed "total" run_items

    finish_progress
}

# The command. No arguments prints the help; -m all runs every mode in turn,
# carries on past one that can't run, and exits 1 at the end if any didn't.
# shellcheck disable=SC2034  # force, check_only and today are read by the modes
update_tools() {
    if (( $# == 0 )); then
        usage
        exit 0
    fi
    force=false check_only=false
    parse_flags "$@"
    if [[ -z "$MODE" ]]; then
        echo "${0##*/}: -m MODE is required" >&2; usage >&2; exit 2
    fi
    if [[ "$MODE" == all && -n "$ROOT_ARG" ]]; then
        echo "${0##*/}: -r can't be used with -m all (each mode has its own folder)" >&2
        exit 2
    fi
    today=$(date +%F)

    local -a modes skipped=()
    local m
    if [[ "$MODE" == all ]]; then modes=(app apw iso); else modes=("$MODE"); fi
    for m in "${modes[@]}"; do
        ITEM_TYPE="$m"; item_settings
        (( ${#modes[@]} > 1 )) && printf '▶ %s\n' "$ITEM_TITLE"
        ( run_mode "$m" ) || skipped+=("$ITEM_TITLE")
    done

    (( ${#skipped[@]} == 0 )) && exit 0
    if (( ${#modes[@]} > 1 )); then
        local list
        printf -v list '%s, ' "${skipped[@]}"
        printf '⚠ skipped: %s\n' "${list%, }"
    fi
    exit 1
}
