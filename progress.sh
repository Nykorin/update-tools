# progress.sh – optional live status block
# If this file is missing the main scripts fall back to plain output.

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
curl_abandon()   { if (( PROGRESS_ON )); then BLOCK_DRAWN=0; printf '\r'; fi; }

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
