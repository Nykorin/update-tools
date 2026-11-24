# shellcheck shell=bash disable=SC2154
# cli.sh: the flags and the help text. Loaded by load.sh.
# SC2154: cfg keys and per-item variables are assigned outside this file.

ROOT_ARG=""
# What -m asked for: app, apw or iso, all (all three, no menu), or empty
# (no -m: the menu on a terminal, all three otherwise).
RUN_TYPE=""
# update-tools remove: REMOVE=1, with the AppImages to remove (cfg names) in
# REMOVE_NAMES; none means pick them with fzf. Implies -m app.
REMOVE=0 REMOVE_NAMES=()

# The help: -h prints the overview (usage), -h TOPIC one part of it
# (help_topic). A bad option prints the overview to stderr. Folders and the
# skip are the ones the settings file sets.
HELP_TOPICS="modes menu settings remove make all"

# Sets app, apw, iso and skip (help_modes, help_settings) from the settings.
help_settings_vars() {
    load_settings
    app=$(tilde "${app_dir:-$HOME/AppImages}"); [[ -n "${app_dir:-}" ]] || app+=" (the default)"
    apw=$(tilde "${apw_dir:-(not set)}")
    iso=$(tilde "${iso_dir:-(not set)}")
    if (( SKIP_SECONDS )); then
        skip="on, skip_hours=$(( SKIP_SECONDS / 3600 )): items checked in the last $(( SKIP_SECONDS / 3600 )) h are skipped"
    else
        skip="off: every item is checked on every run"
    fi
}

usage() {
    cat <<EOF
Usage: ${0##*/} [-m MODE] [OPTIONS]
       ${0##*/} remove [NAME...]
       ${0##*/} make -m MODE [OPTIONS] LINK [NAME]
Check and update AppImages, Archipelago worlds and ISOs. Without -m, on a
terminal, a menu (fzf) picks what to update.

Options:
  -m, --mode MODE   app, apw, iso or all, without the menu (-h modes)
  -c, --check       only look for updates: download and change nothing
  -f, --force       check every item, even ones checked within skip_hours;
                    for AppImages, also rebuild each desktop entry and its icon
  -r, --root DIR    use DIR instead of the mode's folder (only with -m app,
                    apw or iso)
  -d, --debug       explain each decision and time each item (or DEBUG=1)
  -h, --help [TOPIC]
                    show this help, or one topic

Topics (-h TOPIC):
  modes             what each mode updates, and from where
  menu              the menu, without -m
  settings          the settings file, and what it sets now
  remove            removing AppImages (${0##*/} remove -h)
  make              writing a new item's cfg (${0##*/} make -h)
  all               every topic
EOF
}

help_modes() {
    local app apw iso skip
    help_settings_vars
    [[ -n "${apw_dir:-}" ]] || apw="no folder set (-h settings)"
    [[ -n "${iso_dir:-}" ]] || iso="no folder set (-h settings)"
    cat <<EOF
Modes:
  app, appimages    the AppImages: $app
                    (desktop entries go to ~/.local/share/applications, from
                    db/NAME.desktop if there is one)
  apw, apworlds     the Archipelago custom worlds: $apw
  iso, isos         the ISOs on a Ventoy drive: $iso
                    (each cfg's "folder" names the ISO's folder, and every
                    download is checksum-verified before it replaces anything)
  all               all three in turn, skipping any that can't run

Each item has a cfg (NAME.json) in its folder's .update-tools/db/; one whose
item isn't there yet is installed. Without -m, and without a terminal or fzf,
all three run.
EOF
}

help_menu() {
    cat <<EOF
Menu:
Without -m, on a terminal with fzf, a menu picks what to update:
  1. the kinds (Tab marks several, Enter takes them, Esc quits)
  2. for each kind, "check all" (the first line), or single marked items,
     which are updated directly; Esc goes back
  3. after the check, which downloads nothing, the updates found are listed,
     all marked: Enter downloads what's still marked, Esc nothing
With -c the run ends after the check. The check's output is in the session
log (~/.cache/update-tools/), whose path the list shows.
EOF
}

help_settings() {
    local app apw iso skip
    help_settings_vars
    cat <<EOF
Settings ($(tilde "$SETTINGS_FILE")):
  app_dir=          $app
  apw_dir=          $apw
  iso_dir=          $iso
  skip_checked=     $skip

One key=value per line. skip_checked=off checks every item on every run;
skip_hours (default 24; 168 is weekly) sets how long a check counts. -f
ignores both for one run.
EOF
}

help_remove() {
    cat <<EOF
Usage: ${0##*/} remove [OPTIONS] [NAME...]
Remove AppImages: each NAME is a cfg's name (db/NAME.json). Without NAME, pick
from the installed AppImages (fzf; Tab marks several), on a terminal.

It removes the AppImage, its desktop entry, its icon (unless another entry uses
it), db/NAME.desktop and db/NAME.json. On a terminal it lists the files and
asks first.

Options:
  -c, --check       only list the files, remove nothing
  -r, --root DIR    the AppImages folder (default: app_dir)
  -d, --debug       explain each decision (or DEBUG=1)
  -h, --help        show this help
EOF
}

# -h TOPIC: one part of the help; every part for "all".
help_topic() {
    local t
    case "$1" in
        modes)     help_modes ;;
        menu)      help_menu ;;
        settings)  help_settings ;;
        remove)    help_remove ;;
        make)      make_usage ;;
        all)
            usage
            for t in modes menu settings remove make; do
                echo; help_topic "$t"
            done ;;
        *)
            echo "${0##*/}: no help topic '$1' (${HELP_TOPICS// /, })" >&2
            exit 2 ;;
    esac
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
        -e "s/^(Usage|Settings|Options|Topics|Modes|Menu):?/$C_BOLD$C_YELLOW&$C_R/" \
        -e "s/^(LINK|NAME):/$C_YELLOW\1$C_R:/" \
        -e "s/(^|[ (/,[|])(--?[a-z][a-z-]*)/\1$C_GREEN\2$C_R/g" \
        -e "s/\b(DIR|TYPE|MODE|LINK|NAME|OPTIONS|TOPIC)\b/$C_YELLOW\1$C_R/g"
}


# Sets RUN_TYPE (-m), force, check_only, DEBUG, REMOVE_NAMES (the words after
# remove, with REMOVE set by update_tools) and ROOT_ARG (-r, only with -m app,
# apw or iso); -h prints usage (remove's help after remove), and a bad option
# prints it to stderr.
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
            -h|--help|--help=*)
                if [[ "$1" == --help=* ]]; then
                    m="${1#--help=}"
                elif [[ -n "${2:-}" && "$2" != -* ]]; then
                    m="$2"
                elif (( REMOVE )); then
                    help_remove | paint_text; exit 0
                else
                    usage | paint_text; exit 0
                fi
                # a wrong topic's error first, outside the pipe (its exit 2)
                [[ " $HELP_TOPICS " == *" $m "* ]] || help_topic "$m"
                help_topic "$m" | paint_text; exit 0 ;;
            -*|"")      echo "${0##*/}: unknown option '$1'" >&2; usage >&2; exit 2 ;;
            *)
                # remove's NAMEs: cfg names, never paths
                if (( ! REMOVE )); then
                    echo "${0##*/}: unknown argument '$1'" >&2; usage >&2; exit 2
                fi
                if [[ "$1" == */* || "$1" == . || "$1" == .. ]]; then
                    echo "${0##*/} remove: NAME is an AppImage's cfg name (db/NAME.json), not '$1'" >&2
                    exit 2
                fi
                REMOVE_NAMES+=("${1%.json}") ;;
        esac
        shift
    done
    if (( REMOVE )); then
        case "$RUN_TYPE" in
            "")  RUN_TYPE=app ;;
            app) ;;
            *)   echo "${0##*/} remove: only AppImages can be removed (-m app)" >&2; exit 2 ;;
        esac
    fi
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
# update-tools make).
# shellcheck disable=SC2034  # MODE is read by make_cfg
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
