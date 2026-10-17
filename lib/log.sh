# shellcheck shell=bash disable=SC2154
# log.sh: debug lines and -d timings. Loaded by load.sh.
# SC2154: cfg keys and per-item variables are assigned outside this file.

case "${DEBUG:-0}" in 0|"") DEBUG=0 ;; *) DEBUG=1 ;; esac

# A decision-trace line. It goes through say, so never call it inside $(...)
# (it would be captured) or while curl owns line 2.
debug() {
    (( DEBUG )) || return 0
    say "  · ${PROGRESS_LABEL:-}: $*"
}

# timed's report files, innermost last, so the EXIT trap can remove them
TIMED_FILES=()

# timed LABEL CMD...: run CMD in this shell; with -d, report how long it took,
# measured with bash's time keyword. The report goes to a temp file so it can't
# land in the status block; CMD's own stderr is untouched. An empty LABEL means
# the item being handled.
timed() {
    local label="$1" rc tf took
    shift
    if (( ! DEBUG )); then "$@"; return; fi
    tf=$(mktemp)
    TIMED_FILES+=("$tf")
    local TIMEFORMAT='%3R %3U %3S'
    { time "$@" 2>&3; } 3>&2 2>"$tf"
    rc=$?
    # bash 5.3 can print a rounding carry as ':' ("0.:0" for 1.00), so read each
    # digit by its value instead of trusting the text
    took=$(awk '
        function sec(x,   i, n, v, p) {
            n = index(x, "."); if (!n) return x + 0
            v = substr(x, 1, n - 1) + 0; p = 1
            for (i = n + 1; i <= length(x); i++) { p /= 10; v += (index("0123456789:", substr(x, i, 1)) - 1) * p }
            return v }
        function fmt(v) { return v >= 60 ? sprintf("%dm%.2fs", int(v / 60), v - 60 * int(v / 60)) : sprintf("%.2fs", v) }
        { printf "%s (user %s, sys %s)", fmt(sec($1)), fmt(sec($2)), fmt(sec($3)) }' "$tf")
    rm -f "$tf"
    unset 'TIMED_FILES[-1]'
    commit_final   # the item's result line first, then its time
    say "  · ${label:-${PROGRESS_LABEL:-}}: took $took"
    return "$rc"
}
