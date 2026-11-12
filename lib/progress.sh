# progress.sh: the live status block on a terminal, and plain lines otherwise
# (PROGRESS_ON). Required, loaded first by load.sh: say and the status functions
# live here.
# shellcheck shell=bash

PROGRESS_ON=0
PROGRESS_TOTAL=0
PROGRESS_DONE=0
PROGRESS_LABEL=""
PROGRESS_COLS=80
STATUS=""
FINAL_STATUS=""
BLOCK_DRAWN=0

# Colours, only on a terminal and not with NO_COLOR set (no-color.org) or
# TERM=dumb, so plain output never gets escape codes. The codes have no width,
# so they go in after anything is cut to the terminal's width.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
    C_R=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m'
    C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m'
else
    C_R="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
fi

# Sets variable $1 to text $2 with its glyphs coloured: ✓ green, ✗ red,
# ⚠ yellow, ⬆ ⬇ cyan; a debug line ("  · …") is dimmed whole.
paint() {
    local t="$2"
    if [[ -n "$C_R" ]]; then
        if [[ "$t" == "  · "* ]]; then
            t="$C_DIM$t$C_R"
        else
            t="${t//✓/$C_GREEN✓$C_R}"; t="${t//✗/$C_RED✗$C_R}"
            t="${t//⚠/$C_YELLOW⚠$C_R}"
            t="${t//⬆/$C_CYAN⬆$C_R}"; t="${t//⬇/$C_CYAN⬇$C_R}"
        fi
    fi
    printf -v "$1" '%s' "$t"
}

block_erase() {
    (( PROGRESS_ON && BLOCK_DRAWN )) || return 0
    printf '\r\033[K\033[1A\r\033[K'
    BLOCK_DRAWN=0
}

block_draw() {
    (( PROGRESS_ON )) || return 0
    local percent filled fill empty line1 label rest
    percent=$(( PROGRESS_DONE * 100 / PROGRESS_TOTAL ))
    filled=$(( PROGRESS_DONE * 20 / PROGRESS_TOTAL ))
    printf -v fill '%*s' "$filled" ''
    printf -v empty '%*s' "$(( 20 - filled ))" ''
    line1="$PROGRESS_LABEL${STATUS:+ $STATUS}"
    line1="${line1:0:PROGRESS_COLS-4}"
    label="${line1:0:${#PROGRESS_LABEL}}"
    paint rest "${line1:${#PROGRESS_LABEL}}"
    printf '%s\n[%s%s] %d%% (%d/%d)' "${label:+$C_BOLD$label$C_R}$rest" \
        "$C_GREEN${fill// /#}$C_R" "$C_DIM${empty// /.}$C_R" \
        "$percent" "$PROGRESS_DONE" "$PROGRESS_TOTAL"
    BLOCK_DRAWN=1
}

block_redraw() { block_erase; block_draw; }

# Copies a permanent line, plain, to the session log (RUN_LOG, start_log).
run_log() {
    [[ -n "${RUN_LOG:-}" ]] && printf '%s\n' "$*" >> "$RUN_LOG"
    return 0
}

say() {
    local text
    run_log "$*"
    paint text "$*"
    block_erase
    printf '%s\n' "$text"
    block_draw
}

status() {
    STATUS="$1"
    if (( PROGRESS_ON )); then
        block_redraw
    else
        printf '%s %s\n' "$PROGRESS_LABEL" "$1"
    fi
}

status_final() {
    run_log "$PROGRESS_LABEL $1"
    FINAL_STATUS="$1"
    status "$1"
}

commit_final() {
    [[ -n "$FINAL_STATUS" ]] || return 0
    if (( PROGRESS_ON )); then
        local text
        paint text "$FINAL_STATUS"
        block_erase
        printf '%s %s\n' "$C_BOLD$PROGRESS_LABEL$C_R" "$text"
    fi
    FINAL_STATUS=""
}

curl_takeover() { (( PROGRESS_ON )) && printf '\r\033[K'; return 0; }
curl_handback()  { if (( PROGRESS_ON )); then printf '\033[1A'; block_redraw; fi; }

# A failed curl leaves its bar plus an error that can wrap or add a blank
# line, so count the rows it used to find line 1 again. Copy goes to stdout,
# where the block is.
# The log is global so the EXIT trap can remove it after a Ctrl+C.
CURL_ROWS=0
CURL_BLANK=0
CURL_LOG=""
curl_run() {
    (( PROGRESS_ON )) || { curl "$@"; return; }
    local rc
    CURL_LOG=$(mktemp)
    COLUMNS="$PROGRESS_COLS" curl "$@" 2>&1 | tee "$CURL_LOG"
    rc=${PIPESTATUS[0]}
    # rows = line breaks + wraps; only text after the last \r is still shown
    read -r CURL_ROWS CURL_BLANK < <(awk -v cols="$PROGRESS_COLS" '
        { sub(/\r+$/, ""); sub(/.*\r/, ""); n = length($0)
          if (n) { wraps += int((n - 1) / cols); blank = 0 } else blank++ }
        END { print NR + wraps, blank + 0 }' "$CURL_LOG")
    [[ -n "$(tail -c1 "$CURL_LOG")" ]] && (( CURL_ROWS-- ))
    rm -f "$CURL_LOG"
    return "$rc"
}

# Delete line 1 (the stale status), keep curl's output minus its trailing
# blank lines, and leave the cursor on a clean line below it.
curl_abandon() {
    (( PROGRESS_ON )) || return 0
    local down=$(( CURL_ROWS - CURL_BLANK ))
    printf '\r\033[%dA\033[M' "$(( CURL_ROWS + 1 ))"
    (( down > 0 )) && printf '\033[%dB' "$down"
    printf '\r\033[J'
    BLOCK_DRAWN=0
}

init_progress() {
    local total="$1"
    PROGRESS_TOTAL=$total
    if [[ -t 1 ]] && (( total > 0 )); then
        PROGRESS_ON=1
        local term_cols=0
        read -r _ term_cols < <(stty size 2>/dev/null)
        (( term_cols > 0 )) && PROGRESS_COLS=$term_cols
    fi
}

finish_progress() {
    commit_final
    PROGRESS_DONE=$PROGRESS_TOTAL
    PROGRESS_LABEL="Done"
    if declare -f rate_summary >/dev/null; then
        rate_summary
        [[ -n "$STATUS" ]] && run_log "$STATUS"
    else
        STATUS=""
    fi
    block_redraw
    if (( PROGRESS_ON )); then
        printf '\n'
    elif [[ -n "$STATUS" ]]; then
        printf '%s\n' "$STATUS"
    fi
}
