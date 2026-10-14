# shellcheck shell=bash disable=SC2154
# cli.sh: the flags and the help text. Loaded by load.sh.
# Cfg keys (manager, url, ...) are set by load_cfg through printf -v, and the
# per-item variables by process_item, so shellcheck can't see them assigned here.

# ---------------------------------------------------------------------------
# Flags, the same in every updater
# ---------------------------------------------------------------------------
ROOT_ARG=""

# The help text, shared by every updater: item_settings in lib/update-tools sets
# USAGE_ABOUT (what it updates and where), ITEM_EXT (appimage, apworld, iso) and
# USAGE_ROOT (the rest of the -r line, continuation lines indented to the
# description column).
usage() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS]
$USAGE_ABOUT

Options:
  -c, --check       only look for updates: download and change nothing
  -f, --force       check every $ITEM_EXT, even ones already checked today
  -r, --root DIR    use DIR instead of $USAGE_ROOT
  -d, --debug       explain each decision and time each $ITEM_EXT (or DEBUG=1)
  -h, --help        show this help
EOF
}

# Sets the caller's force and check_only, DEBUG, and ROOT_ARG (-r); -h prints
# usage, and a bad option prints it to stderr.
# shellcheck disable=SC2034  # force and check_only are main's locals
parse_flags() {
    while (( $# )); do
        case "$1" in
            -c|--check) check_only=true ;;
            -f|--force) force=true ;;
            -r|--root)
                if [[ -z "${2:-}" ]]; then
                    echo "${0##*/}: $1 needs a folder" >&2; usage >&2; exit 2
                fi
                ROOT_ARG="$2"; shift ;;
            --root=*)   ROOT_ARG="${1#--root=}" ;;
            -d|--debug) DEBUG=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          echo "${0##*/}: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
}
