# shellcheck shell=bash disable=SC2154
# cli.sh: the flags and the help text. Loaded by load.sh.
# SC2154: cfg keys and per-item variables are assigned outside this file.

ROOT_ARG=""
# The command's mode: app, apw or iso for update-appimages, update-apworlds and
# update-isos; empty for update-tools, which runs all three.
RUN_TYPE=""

# The help text: -h, and after a bad option (to stderr). The folders and the
# skip are the ones the settings file sets.
usage() {
    local app apw iso skip folders
    load_settings
    app=$(tilde "${app_dir:-$HOME/AppImages}"); [[ -n "${app_dir:-}" ]] || app+=" (the default)"
    apw=$(tilde "${apw_dir:-(not set)}")
    iso=$(tilde "${iso_dir:-(not set)}")
    if (( SKIP_SECONDS )); then
        skip="on, skip_hours=$(( SKIP_SECONDS / 3600 )): items checked in the last $(( SKIP_SECONDS / 3600 )) h are skipped"
    else
        skip="off: every item is checked on every run"
    fi
    case "$RUN_TYPE" in
        app)
            cat <<EOF
Usage: ${0##*/} [OPTIONS]
Check and update the AppImages. Each has a cfg (NAME.appimage.cfg) in the
folder's .cfg/; one whose AppImage isn't there yet is installed. Desktop
entries go to ~/.local/share/applications.
EOF
            folders="  app_dir=          $app" ;;
        apw)
            cat <<EOF
Usage: ${0##*/} [OPTIONS]
Check and update the Archipelago custom worlds. Each has a cfg
(NAME.apworld.cfg) in the folder's .cfg/; one whose world isn't there yet is
installed.
EOF
            folders="  apw_dir=          $apw" ;;
        iso)
            cat <<EOF
Usage: ${0##*/} [OPTIONS]
Check and update the ISOs on a Ventoy drive. Each has a cfg (NAME.iso.cfg) in
the root's .cfg/, whose folder= names the ISO's folder; one whose ISO isn't
there yet is installed. Every download is checksum-verified before it
replaces anything.
EOF
            folders="  iso_dir=          $iso" ;;
        *)
            cat <<EOF
Usage: ${0##*/} [OPTIONS]
Check and update AppImages, Archipelago worlds and ISOs: runs update-appimages,
update-apworlds and update-isos in turn, skipping any that can't run. Each of
them can also be run on its own, with -r DIR for another folder.
EOF
            folders="  app_dir=          $app
  apw_dir=          $apw
  iso_dir=          $iso" ;;
    esac
    cat <<EOF

Settings ($(tilde "$SETTINGS_FILE")):
$folders
  skip_checked=     $skip

Options:
  -c, --check       only look for updates: download and change nothing
EOF
    if [[ "$RUN_TYPE" == app || -z "$RUN_TYPE" ]]; then
        echo "  -f, --force       check every item, even ones checked within skip_hours;"
        echo "                    for AppImages, also rebuild each desktop entry and its icon"
    else
        echo "  -f, --force       check every item, even ones checked within skip_hours"
    fi
    [[ -n "$RUN_TYPE" ]] && echo "  -r, --root DIR    use DIR instead of the folder set above"
    cat <<EOF
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
        -e "s/\b(DIR|TYPE|LINK|NAME|OPTIONS)\b/$C_YELLOW\1$C_R/g"
}


# Sets force, check_only, DEBUG, and ROOT_ARG (-r, not for update-tools); -h
# prints usage, and a bad option prints it to stderr.
# shellcheck disable=SC2034  # force and check_only are read by the modes
parse_flags() {
    while (( $# )); do
        case "$1" in
            -c|--check) check_only=true ;;
            -f|--force) force=true ;;
            -r|--root|--root=*)
                if [[ -z "$RUN_TYPE" ]]; then
                    echo "${0##*/}: -r can't be used here (each mode has its own folder); run update-appimages, update-apworlds or update-isos with -r DIR" >&2
                    exit 2
                fi
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
}

# MODE, the short name for either spelling of mode $1 (make-update-cfg's -m).
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
