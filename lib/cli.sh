# shellcheck shell=bash disable=SC2154
# cli.sh: the flags and the help text. Loaded by load.sh.
# SC2154: cfg keys and per-item variables are assigned outside this file.

ROOT_ARG=""
MODE=""

# The help text: -h, no arguments, and after a bad option (to stderr). The
# folders are the ones the paths file sets.
usage() {
    local app apw iso
    load_paths
    app=$(tilde "${app_dir:-$HOME/AppImages}"); [[ -n "${app_dir:-}" ]] || app+=" (the default)"
    apw=$(tilde "${apw_dir:-(not set)}")
    iso=$(tilde "${iso_dir:-(not set)}")
    cat <<EOF
Usage: ${0##*/} -m MODE [OPTIONS]
Check and update AppImages, Archipelago worlds and ISOs. Each item has a cfg
(NAME.appimage.cfg, NAME.apworld.cfg or NAME.iso.cfg) in its folder's .cfg/;
one whose item isn't there yet is installed.

Modes:
  app, appimages    the AppImages (desktop entries go to
                    ~/.local/share/applications)
  apw, apworlds     the Archipelago custom worlds
  iso, isos         the ISOs on a Ventoy drive; each cfg's
                    folder= names the ISO's folder, and every download is
                    checksum-verified before it replaces anything
  all               all three in turn, skipping any that can't run

Folders ($(tilde "$PATHS_FILE")):
  app_dir=          $app
  apw_dir=          $apw
  iso_dir=          $iso

Options:
  -m, --mode MODE   what to update (required; see Modes)
  -c, --check       only look for updates: download and change nothing
  -f, --force       check every item, even ones already checked today; for
                    AppImages, also rebuild each desktop entry and its icon
  -r, --root DIR    use DIR instead of the mode's folder (not with -m all)
  -d, --debug       explain each decision and time each item (or DEBUG=1)
  -h, --help        show this help
EOF
}


# Sets MODE (-m), force, check_only, DEBUG, and ROOT_ARG (-r); -h prints usage,
# and a bad option prints it to stderr.
# shellcheck disable=SC2034  # force and check_only are read by the modes
parse_flags() {
    while (( $# )); do
        case "$1" in
            -m|--mode)
                if [[ -z "${2:-}" ]]; then
                    echo "${0##*/}: $1 needs a mode" >&2; usage >&2; exit 2
                fi
                set_mode "$2"; shift ;;
            --mode=*)   set_mode "${1#--mode=}" ;;
            -c|--check) check_only=true ;;
            -f|--force) force=true ;;
            -r|--root)
                if [[ -z "${2:-}" ]]; then
                    echo "${0##*/}: $1 needs a folder" >&2; usage >&2; exit 2
                fi
                ROOT_ARG="$2"; shift ;;
            --root=*)
                # empty would quietly fall back to the mode's real folder
                if [[ -z "${1#--root=}" ]]; then
                    echo "${0##*/}: --root needs a folder" >&2; usage >&2; exit 2
                fi
                ROOT_ARG="${1#--root=}" ;;
            -d|--debug) DEBUG=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          echo "${0##*/}: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
}

# MODE, the short name for either spelling of mode $1.
# shellcheck disable=SC2034  # MODE is read by update_tools (main.sh)
set_mode() {
    case "$1" in
        app|appimages) MODE=app ;;
        apw|apworlds)  MODE=apw ;;
        iso|isos)      MODE=iso ;;
        all)           MODE=all ;;
        *)
            echo "${0##*/}: unknown mode '$1' (app, apw, iso or all)" >&2; usage >&2; exit 2
            ;;
    esac
}
