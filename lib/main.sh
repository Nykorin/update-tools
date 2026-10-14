# shellcheck shell=bash
# main.sh: what update-tools runs. update_tools parses the flags and runs each
# mode in its own subshell (run_mode), which loads that mode's module
# (appimages.sh, apworlds.sh or isos.sh: prepare_dir and process_item) and walks
# its cfgs. A subshell per mode keeps one mode's variables, traps and failures
# out of the next one under -m all.

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
