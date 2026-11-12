# shellcheck shell=bash disable=SC2154
# cli.sh: the flags and the help text. Loaded by load.sh.
# SC2154: cfg keys and per-item variables are assigned outside this file.

ROOT_ARG=""
# What -m asked for: app, apw or iso, all (all three, no menu), or empty
# (no -m: the menu on a terminal, all three otherwise).
RUN_TYPE=""

# The help text: -h, and after a bad option (to stderr). The folders and the
# skip are the ones the settings file sets.
usage() {
    local app apw iso skip
    load_settings
    app=$(tilde "${app_dir:-$HOME/AppImages}"); [[ -n "${app_dir:-}" ]] || app+=" (the default)"
    apw=$(tilde "${apw_dir:-(not set)}")
    iso=$(tilde "${iso_dir:-(not set)}")
    if (( SKIP_SECONDS )); then
        skip="on, skip_hours=$(( SKIP_SECONDS / 3600 )): items checked in the last $(( SKIP_SECONDS / 3600 )) h are skipped"
    else
        skip="off: every item is checked on every run"
    fi
    cat <<EOF
Usage: ${0##*/} [-m MODE] [OPTIONS]
Check and update AppImages, Archipelago worlds and ISOs. Each item has a cfg
(NAME.json) in its folder's .update-tools/db/; one whose item isn't there yet
is installed.

Without -m, on a terminal, a menu (fzf) picks what to update: the kinds, then
for each either all its items (checked first, then the updates found are
offered for download) or single items. Without a terminal, or without fzf, it
runs all three.

Modes:
  app, appimages    the AppImages (desktop entries go to
                    ~/.local/share/applications, from db/NAME.desktop if
                    there is one)
  apw, apworlds     the Archipelago custom worlds
  iso, isos         the ISOs on a Ventoy drive; each cfg's "folder" names the
                    ISO's folder, and every download is checksum-verified
                    before it replaces anything
  all               all three in turn, skipping any that can't run

Settings ($(tilde "$SETTINGS_FILE")):
  app_dir=          $app
  apw_dir=          $apw
  iso_dir=          $iso
  skip_checked=     $skip

Options:
  -m, --mode MODE   what to update (see Modes), without the menu
  -c, --check       only look for updates: download and change nothing
  -f, --force       check every item, even ones checked within skip_hours;
                    for AppImages, also rebuild each desktop entry and its icon
  -r, --root DIR    use DIR instead of the mode's folder (only with -m app,
                    apw or iso)
  -d, --debug       explain each decision and time each item (or DEBUG=1)
  -h, --help        show this help
EOF
}

# Colours the help text on its way to a terminal, as system-update's -h does:
# the command names (bold on the Usage: lines), the headings, options and
# placeholders. Plain when piped, redirected, or with NO_COLOR or TERM=dumb
# (the C_* colours are empty then). Errors print the help plain to stderr.
paint_text() {
    [[ -n "$C_R" ]] || { cat; return; }
    local cmd='update-(tools|appimages|apworlds|isos)|make-update-cfg'
    sed -E \
        -e "s/^(Usage: |       )($cmd)\b/\1$C_BOLD$C_CYAN\2$C_R/" \
        -e "s/(^|[ (,])($cmd)([ ,:)]|$)/\1$C_CYAN\2$C_R\4/g" \
        -e "s/^(Usage|Settings|Options):?/$C_BOLD$C_YELLOW&$C_R/" \
        -e "s/^(LINK|NAME):/$C_YELLOW\1$C_R:/" \
        -e "s/(^|[ (/,[|])(--?[a-z][a-z-]*)/\1$C_GREEN\2$C_R/g" \
        -e "s/\b(DIR|TYPE|MODE|LINK|NAME|OPTIONS)\b/$C_YELLOW\1$C_R/g"
}


# Sets RUN_TYPE (-m), force, check_only, DEBUG and ROOT_ARG (-r, only with
# -m app, apw or iso); -h prints usage, and a bad option prints it to stderr.
# shellcheck disable=SC2034  # force and check_only are read by the modes
parse_flags() {
    local m
    while (( $# )); do
        case "$1" in
            -m|--mode|--mode=*)
                if [[ "$1" == --mode=* ]]; then
                    m="${1#--mode=}"
                else
                    m="${2:-}"; (( $# > 1 )) && shift
                fi
                case "$m" in
                    all) RUN_TYPE=all ;;
                    "")  echo "${0##*/}: ${1%%=*} needs a mode" >&2; usage >&2; exit 2 ;;
                    app|appimages|apw|apworlds|iso|isos) set_mode "$m"; RUN_TYPE="$MODE" ;;
                    *)   echo "${0##*/}: unknown mode '$m' (app, apw, iso or all)" >&2; usage >&2; exit 2 ;;
                esac ;;
            -c|--check) check_only=true ;;
            -f|--force) force=true ;;
            -r|--root|--root=*)
                if [[ "$1" == --root=* ]]; then
                    ROOT_ARG="${1#--root=}"
                else
                    ROOT_ARG="${2:-}"; (( $# > 1 )) && shift
                fi
                # empty would quietly fall back to the mode's real folder
                if [[ -z "$ROOT_ARG" ]]; then
                    echo "${0##*/}: ${1%%=*} needs a folder" >&2; usage >&2; exit 2
                fi ;;
            -d|--debug) DEBUG=1 ;;
            -h|--help)  usage | paint_text; exit 0 ;;
            *)          echo "${0##*/}: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
    case "$RUN_TYPE" in
        app|apw|iso) ;;
        *)
            if [[ -n "$ROOT_ARG" ]]; then
                echo "${0##*/}: -r needs -m app, apw or iso (each mode has its own folder)" >&2
                exit 2
            fi ;;
    esac
}

# MODE, the short name for either spelling of mode $1 (-m, here and in
# make-update-cfg).
# shellcheck disable=SC2034  # MODE is read by make-update-cfg
set_mode() {
    case "$1" in
        app|appimages) MODE=app ;;
        apw|apworlds)  MODE=apw ;;
        iso|isos)      MODE=iso ;;
        *)
            echo "${0##*/}: unknown type '$1' (app, apw or iso)" >&2; usage >&2; exit 2
            ;;
    esac
}
