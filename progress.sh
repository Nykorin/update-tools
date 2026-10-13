# progress.sh – optional live status block
# If this file is missing the main scripts fall back to plain output.
# shellcheck shell=bash

PROGRESS_ON=0
PROGRESS_TOTAL=0
PROGRESS_DONE=0
PROGRESS_LABEL=""
PROGRESS_COLS=80
STATUS=""
FINAL_STATUS=""
BLOCK_DRAWN=0

block_erase() {
    (( PROGRESS_ON && BLOCK_DRAWN )) || return 0
    printf '\r\033[K\033[1A\r\033[K'
    BLOCK_DRAWN=0
}

block_draw() {
    (( PROGRESS_ON )) || return 0
    local percent filled fill empty line1
    percent=$(( PROGRESS_DONE * 100 / PROGRESS_TOTAL ))
    filled=$(( PROGRESS_DONE * 20 / PROGRESS_TOTAL ))
    printf -v fill '%*s' "$filled" ''
    printf -v empty '%*s' "$(( 20 - filled ))" ''
    line1="$PROGRESS_LABEL${STATUS:+ $STATUS}"
    printf '%s\n[%s%s] %d%% (%d/%d)' "${line1:0:PROGRESS_COLS-4}" \
        "${fill// /#}" "${empty// /.}" "$percent" "$PROGRESS_DONE" "$PROGRESS_TOTAL"
    BLOCK_DRAWN=1
}

block_redraw() { block_erase; block_draw; }

say() {
    block_erase
    printf '%s\n' "$*"
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
    FINAL_STATUS="$1"
    status "$1"
}

commit_final() {
    [[ -n "$FINAL_STATUS" ]] || return 0
    if (( PROGRESS_ON )); then
        block_erase
        printf '%s %s\n' "$PROGRESS_LABEL" "$FINAL_STATUS"
    fi
    FINAL_STATUS=""
}

curl_takeover() { (( PROGRESS_ON )) && printf '\r\033[K'; return 0; }
curl_handback()  { if (( PROGRESS_ON )); then printf '\033[1A'; block_redraw; fi; }

# A failed curl leaves its bar plus an error that can wrap or add a blank
# line, so count the rows it used to find line 1 again. Copy goes to stdout,
# where the block is.
CURL_ROWS=0
CURL_BLANK=0
curl_run() {
    (( PROGRESS_ON )) || { curl "$@"; return; }
    local log rc
    log=$(mktemp)
    COLUMNS="$PROGRESS_COLS" curl "$@" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    # rows = line breaks + wraps; only the text after the last \r is still on screen
    read -r CURL_ROWS CURL_BLANK < <(awk -v cols="$PROGRESS_COLS" '
        { sub(/\r+$/, ""); sub(/.*\r/, ""); n = length($0)
          if (n) { wraps += int((n - 1) / cols); blank = 0 } else blank++ }
        END { print NR + wraps, blank + 0 }' "$log")
    [[ -n "$(tail -c1 "$log")" ]] && (( CURL_ROWS-- ))
    rm -f "$log"
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
