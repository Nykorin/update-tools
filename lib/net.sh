# shellcheck shell=bash disable=SC2154
# net.sh: network timeouts, GitHub and GitLab requests, rate tracking and the
# GitHub token. Loaded by load.sh.
# SC2154: cfg keys and per-item variables are assigned outside this file.

# A server that accepts the connection and then never answers would hang a run.
# Small requests get a hard limit; downloads only fail when they stall, so a
# big ISO on a slow line still finishes.
CURL_META=(--connect-timeout 20 --max-time 120)
# shellcheck disable=SC2034  # used by the updaters' download lines
CURL_DL=(--connect-timeout 20 --speed-limit 1024 --speed-time 60)

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------
GITHUB_HEADERS=""
GITHUB_CALLS=0
GITHUB_FREE=0
GITHUB_LIMIT=""
GITHUB_REMAINING=""
GITHUB_RESET=""
GITHUB_ETAG=""
GITHUB_LINK_NEXT=""
GITHUB_MOVED=""
GITHUB_RATE_LIMITED=0
declare -A GITHUB_CACHE=() GITHUB_ETAGS=() GITHUB_NEXT=()

# Prints the body, then the HTTP status code on its own last line.
# $2 = optional ETag to send as If-None-Match. -L follows renamed or transferred
# repos; GitHub redirects within api.github.com, so the token stays there.
github_api() {
    local -a args=(-sL "${CURL_META[@]}" -w '\n%{http_code}' -D "$GITHUB_HEADERS")
    [[ -n "${2:-}" ]] && args+=(-H "If-None-Match: $2")
    : > "$GITHUB_HEADERS"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl "${args[@]}" -H @- "$1" <<<"Authorization: Bearer $GITHUB_TOKEN"
    else
        curl "${args[@]}" "$1"
    fi
}

# Sets release_json and remote_etag for $1, fetching each URL once per run. Call
# it directly, never inside $(...), or the cache is lost with the subshell. $2 =
# the ETag this item saved last time; a 304 for it means nothing changed.
# Returns 1 to skip this item, 2 when GitHub rate limits us, 3 if unchanged.
github_releases() {
    local api_url="$1" etag="${2:-}" response code when=""
    if [[ -n "${GITHUB_CACHE[$api_url]+set}" ]]; then
        release_json="${GITHUB_CACHE[$api_url]}"
        remote_etag="${GITHUB_ETAGS[$api_url]}"
        debug "GitHub ${api_url#https://api.github.com/}: from this run's cache"
        return 0
    fi
    if (( GITHUB_RATE_LIMITED )); then
        say "⚠ ${PROGRESS_LABEL:-}: GitHub rate limit reached earlier this run, skipping"
        return 2
    fi

    response=$(github_api "$api_url" "$etag")
    read_rate_headers
    code="${response##*$'\n'}"
    release_json="${response%$'\n'*}"
    debug "GitHub ${api_url#https://api.github.com/}${etag:+ (sent ETag)} → HTTP $code, ${GITHUB_REMAINING:-?} requests left"
    [[ -n "$GITHUB_MOVED" ]] && debug "repo ${repo:-} has moved (redirected to $GITHUB_MOVED); consider updating repo= in the cfg"
    # a 304 doesn't count against the limit when the request carries a token
    if [[ "$code" == 304 && -n "${GITHUB_TOKEN:-}" ]]; then
        GITHUB_FREE=$((GITHUB_FREE + 1))
    else
        GITHUB_CALLS=$((GITHUB_CALLS + 1))
    fi

    case "$code" in
        200)
            remote_etag="$GITHUB_ETAG"
            GITHUB_CACHE[$api_url]="$release_json"
            GITHUB_ETAGS[$api_url]="$remote_etag"
            # shellcheck disable=SC2034  # read by resolve_latest_asset
            GITHUB_NEXT[$api_url]="$GITHUB_LINK_NEXT"
            return 0
            ;;
        304)
            remote_etag="$etag"
            return 3
            ;;
        429|403)
            if [[ "$code" == 429 || "${release_json,,}" == *"rate limit"* ]]; then
                GITHUB_RATE_LIMITED=1
                [[ "$GITHUB_RESET" =~ ^[0-9]+$ ]] && printf -v when ' (resets %(%H:%M)T)' "$GITHUB_RESET"
                say "✗ ${PROGRESS_LABEL:-}: GitHub rate limit reached${when}"
                return 2
            fi
            say "⚠ ${PROGRESS_LABEL:-}: GitHub request failed (HTTP 403), skipping"
            ;;
        404)
            say "⚠ ${PROGRESS_LABEL:-}: GitHub repo ${repo:-} not found (HTTP 404), skipping"
            ;;
        000)
            say "⚠ ${PROGRESS_LABEL:-}: no response from GitHub, skipping"
            ;;
        *)
            say "⚠ ${PROGRESS_LABEL:-}: GitHub request failed (HTTP ${code}), skipping"
            ;;
    esac
    return 1
}

# Sets release_json for GitLab project path $1. Returns 1 to skip this item. A
# 429 skips GitLab items only, unlike GitHub's stop: other managers still work.
GITLAB_RATE_LIMITED=0
gitlab_releases() {
    local project="$1" response code
    if (( GITLAB_RATE_LIMITED )); then
        say "⚠ ${PROGRESS_LABEL:-}: GitLab rate limit reached earlier this run, skipping"
        return 1
    fi

    response=$(curl -sL "${CURL_META[@]}" -w '\n%{http_code}' "https://gitlab.com/api/v4/projects/$(urlencode "$project")/releases")
    code="${response##*$'\n'}"
    release_json="${response%$'\n'*}"
    debug "GitLab $project → HTTP $code"

    case "$code" in
        200) return 0 ;;
        429)
            GITLAB_RATE_LIMITED=1
            say "✗ ${PROGRESS_LABEL:-}: GitLab rate limit reached, skipping"
            ;;
        404) say "⚠ ${PROGRESS_LABEL:-}: GitLab project $project not found (HTTP 404), skipping" ;;
        000) say "⚠ ${PROGRESS_LABEL:-}: no response from GitLab, skipping" ;;
        *)   say "⚠ ${PROGRESS_LABEL:-}: GitLab request failed (HTTP $code), skipping" ;;
    esac
    return 1
}

read_rate_headers() {
    local line value next_re='<([^>]*)>; rel="next"'
    GITHUB_ETAG="" GITHUB_LINK_NEXT="" GITHUB_MOVED=""
    while IFS= read -r line; do
        line="${line%$'\r'}"
        value="${line#*:}"; value="${value# }"
        case "${line,,}" in
            x-ratelimit-limit:*)     GITHUB_LIMIT="$value" ;;
            x-ratelimit-remaining:*) GITHUB_REMAINING="$value" ;;
            x-ratelimit-reset:*)     GITHUB_RESET="$value" ;;
            etag:*)                  GITHUB_ETAG="$value" ;;
            link:*)                  [[ "$value" =~ $next_re ]] && GITHUB_LINK_NEXT="${BASH_REMATCH[1]}" ;;
            location:*)              GITHUB_MOVED="$value" ;;
        esac
    done < "$GITHUB_HEADERS"
}

# shellcheck disable=SC2034  # STATUS is drawn by progress.sh
rate_summary() {
    STATUS=""
    (( GITHUB_CALLS + GITHUB_FREE > 0 )) || return 0
    [[ "$GITHUB_LIMIT" =~ ^[0-9]+$ && "$GITHUB_REMAINING" =~ ^[0-9]+$ ]] || return 0
    local warn="" when=""
    (( GITHUB_REMAINING * 10 <= GITHUB_LIMIT )) && warn="⚠ "
    [[ "$GITHUB_RESET" =~ ^[0-9]+$ ]] && printf -v when ', resets %(%H:%M)T' "$GITHUB_RESET"
    STATUS="${warn}GitHub API: $GITHUB_REMAINING/$GITHUB_LIMIT requests left${when} (used $GITHUB_CALLS this run)"
}

# The GitHub token: $GITHUB_TOKEN, else the first line of
# ~/.config/update-tools/github_token, which should be chmod 600.
load_github_token() {
    local token_file="${XDG_CONFIG_HOME:-$HOME/.config}/update-tools/github_token"
    if [[ -z "${GITHUB_TOKEN:-}" && -f "$token_file" ]]; then
        read -r GITHUB_TOKEN < "$token_file"
        [[ "$(stat -c %a "$token_file")" =~ ^[46]00$ ]] \
            || say "⚠ $token_file is readable by other users — run: chmod 600 \"$token_file\""
    fi
}

urlencode() {
    printf '%s' "$1" | sed \
        -e 's|/|%2F|g' \
        -e 's| |%20|g' \
        -e 's|\[|%5B|g' \
        -e 's|\]|%5D|g' \
        -e 's|@|%40|g' \
        -e 's|:|%3A|g'
}
