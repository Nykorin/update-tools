# shellcheck shell=bash disable=SC2154
# run.sh: the required commands, the staged files and the EXIT trap. Loaded by load.sh.
# Cfg keys (manager, url, ...) are set by load_cfg through printf -v, and the
# per-item variables by process_item, so shellcheck can't see them assigned here.

# Each updater's dependencies, by type: app, apw or iso. ;;& goes on to test
# the patterns after it, so a type collects every branch it matches.
require_cmds() {
    local dep
    local -a deps=()
    case "$1" in
        app|apw|iso) deps=(curl) ;;&
        app|apw) deps+=(jq) ;;&
        apw) deps+=(unzip) ;;
        iso) deps+=(sha256sum sha512sum) ;;
    esac
    if (( ${#deps[@]} == 0 )); then
        echo "ERROR: require_cmds: unknown updater type '${1:-}'" >&2
        exit 1
    fi
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || {
            echo "ERROR: required command not found: $dep" >&2
            exit 1
        }
    done
}

# Staged files, global so the EXIT trap can remove them after a Ctrl+C (a
# half-downloaded ISO is useless, and a hidden .part file is easy to forget). Only
# update-appimages extracts, into tmp_extract_dir and DESKTOP_TMP.
tmp_download="" tmp_extract_dir="" DESKTOP_TMP=""

# The EXIT trap: removes the GitHub headers file, curl_run's log, timed's files and
# any staged download or extraction, and puts back an old version still set aside.
# rm -f ignores an empty name, so unset ones need no check.
cleanup() {
    rm -f "$GITHUB_HEADERS" "${CURL_LOG:-}" "${TIMED_FILES[@]}" "$tmp_download"
    rm -rf "$tmp_extract_dir" "$DESKTOP_TMP"
    restore_previous
    return 0
}

# Setup every updater shares: the EXIT trap (cleanup), and the GitHub token and
# headers file (update-isos never contacts GitHub, so they simply go unused there).
start_run() {
    GITHUB_HEADERS=$(mktemp)
    trap cleanup EXIT
    load_github_token
}
