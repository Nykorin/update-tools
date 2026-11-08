# shellcheck shell=bash disable=SC2154
# cfg.sh: reading and saving the item cfgs (JSON) and the settings file.
# Loaded by load.sh.
# SC2154: cfg keys and per-item variables are assigned outside this file.

# Each item's cfg is .cfg/NAME.json: your keys at the top level, the ones the
# scripts write under "state", and an optional "comment" the scripts ignore.
# Values are text (numbers and true/false are read as text too).
#
# The keys you write (ITEM_KEYS) and the ones the scripts keep up to date
# themselves (SAVE_KEYS, in the order new ones are added). load_item sets only
# these as variables: any other name could overwrite one of the scripts' own
# (dir, name, HOME, PATH, ...).
ITEM_KEYS=(
    manager repo repo_filename repo_regex allow_prereleases repo_url
    feed_url channel arch_key download_base url
    apworld_filename icon_name install_name
    checksum checksum_save download_suffix probe_days folder
)
SAVE_KEYS=(current_version last_checked content_length last_modified asset_digest etag
           installed_file iso_hash checksum_file)
CFG_KEYS=("${ITEM_KEYS[@]}" "${SAVE_KEYS[@]}")

# One record per value, NUL-separated: kind (k: a key, s: a state key, b: a
# list or object where text belongs, o: a "state" that isn't an object), key,
# value; then "end", so a cut-off
# stream (bad JSON) can't pass for a short cfg. null counts as unset.
# shellcheck disable=SC2016  # jq code, not shell
ITEM_JQ='
def rec($kind): if .value == null then empty
    elif (.value | type) == "object" or (.value | type) == "array" then "b", .key, ""
    else $kind, .key, (.value | tostring) end;
if type != "object" then error("not a JSON object") else . end
| (to_entries[] | select(.key != "state" and .key != "comment") | rec("k")),
  (.state // {} | if type == "object" then to_entries[] | rec("s") else "o", "state", "" end),
  "end"
| ., "\u0000"'

# Sets the item's keys from its JSON as variables (unset when absent). Returns
# 1, having said why, when the file isn't a valid JSON object.
load_item() {
    local file="$1" i key kind label why
    local -a recs=()
    unset "${CFG_KEYS[@]}"
    mapfile -d '' recs < <(jq -j "$ITEM_JQ" "$file" 2>/dev/null)
    if (( ${#recs[@]} == 0 )) || [[ "${recs[-1]}" != end ]]; then
        # only now, for the message: jq's own reason, with its line and column
        why=$(jq empty "$file" 2>&1 | head -n 1)
        why="${why#jq: }"
        [[ -s "$file" ]] || why="empty file"
        say "⚠ ${PROGRESS_LABEL:-}: ${file##*/} isn't a valid cfg (${why:-not a JSON object}), skipping"
        return 1
    fi
    for (( i = 0; i + 2 < ${#recs[@]}; i += 3 )); do
        kind="${recs[i]}" key="${recs[i+1]}"
        case "$kind" in
            k) label="$key"; [[ " ${ITEM_KEYS[*]} " == *" $key "* ]] ;;
            s) label="state.$key"; [[ " ${SAVE_KEYS[*]} " == *" $key "* ]] ;;
            o) say "⚠ ${PROGRESS_LABEL:-}: 'state' in ${file##*/} isn't an object, ignored"; continue ;;
            *) say "⚠ ${PROGRESS_LABEL:-}: '$key' in ${file##*/} must be text, ignored"; continue ;;
        esac || { say "⚠ ${PROGRESS_LABEL:-}: unknown key '$label' in ${file##*/}, ignored"; continue; }
        printf -v "$key" '%s' "${recs[i+2]}"
    done
}

# Sets KEY=VALUE pairs under the item's "state" in $1, keeping everything else
# (and the order of the keys already there); content_length is saved as a
# number. Written next to the file and renamed over it, so a cut-off write
# never leaves half a cfg.
# shellcheck disable=SC2016  # jq code, not shell
SAVE_JQ='
($ARGS.positional) as $a
| .state = (.state // {}) + ([range(0; $a | length; 2) as $i
    | {($a[$i]): (if $a[$i] == "content_length" then ($a[$i + 1] | tonumber? // $a[$i + 1]) else $a[$i + 1] end)}]
    | add // {})'
save_state() {
    local file="$1" tmp pair
    local -a args=()
    shift
    tmp="${file%/*}/.${file##*/}.tmp"
    for pair; do args+=("${pair%%=*}" "${pair#*=}"); done
    if jq --indent 2 "$SAVE_JQ" "$file" --args "${args[@]}" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"; then
        return 0
    fi
    rm -f "$tmp"
    say "  ✗ ${PROGRESS_LABEL:-}: could not save ${file##*/}"
    return 1
}

# Sets a KEY=VALUE file's keys as variables (the settings file; the item cfgs
# were these too until 2026-11-07). $2… = the keys allowed.
load_cfg() {
    local cfg_file="$1"
    local line key value
    local -a keys=("${@:2}")
    (( ${#keys[@]} )) || keys=("${CFG_KEYS[@]}")

    unset "${keys[@]}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # a cfg saved with Windows line endings: the \r would end every value
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
                value="${value//\\\"/\"}"
            fi
            if [[ " ${keys[*]} " == *" $key "* ]]; then
                printf -v "$key" '%s' "$value"
            else
                say "⚠ ${PROGRESS_LABEL:-}: unknown key '$key' in ${cfg_file##*/}, ignored"
            fi
        fi
    done < "$cfg_file"
}

# The user's settings file (read like a cfg, never sourced): each mode's folder
# (a leading ~ or $HOME is expanded), and whether and for how long an item
# checked recently is skipped. A missing file leaves the folders unset and the
# skip at once per 24 hours.
SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/update-tools/update-tools.cfg"
SETTING_KEYS=(app_dir apw_dir iso_dir skip_checked skip_hours)
SETTINGS_LOADED=0
# seconds an item stays "checked" after its last check; 0: never skipped
SKIP_SECONDS=86400
load_settings() {
    local key value
    (( SETTINGS_LOADED )) && return 0
    SETTINGS_LOADED=1
    [[ -f "$SETTINGS_FILE" ]] || return 0
    PROGRESS_LABEL="${SETTINGS_FILE##*/}" load_cfg "$SETTINGS_FILE" "${SETTING_KEYS[@]}"
    for key in app_dir apw_dir iso_dir; do
        value="${!key:-}"
        # the file's literal text, so the quotes are meant
        # shellcheck disable=SC2088,SC2016
        case "$value" in
            '~'|'~/'*)          value="$HOME${value#\~}" ;;
            '$HOME'|'$HOME/'*)  value="$HOME${value#\$HOME}" ;;
        esac
        printf -v "$key" '%s' "$value"
    done
    case "${skip_checked:-on}" in
        on)  ;;
        off) SKIP_SECONDS=0; return 0 ;;
        *)   say "⚠ ${SETTINGS_FILE##*/}: skip_checked must be on or off (got '$skip_checked'), using on" ;;
    esac
    if [[ "${skip_hours:-24}" =~ ^[1-9][0-9]*$ ]]; then
        SKIP_SECONDS=$(( ${skip_hours:-24} * 3600 ))
    else
        say "⚠ ${SETTINGS_FILE##*/}: skip_hours must be a whole number of hours (got '$skip_hours'), using 24"
    fi
}

# True if the item was checked less than skip_hours ago. Sets CHECKED_AGO, the
# time since, for the message. last_checked is YYYY-MM-DDTHH:MM, or a date
# alone (saved before times were added), read as that day's midnight.
# shellcheck disable=SC2034  # CHECKED_AGO is read by process_item
checked_recently() {
    local stamp age
    (( SKIP_SECONDS )) || return 1
    [[ "${last_checked:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2})?$ ]] || return 1
    stamp=$(date -d "${last_checked/T/ }" +%s 2>/dev/null) || return 1
    age=$(( NOW - stamp ))
    # a time in the future (a changed clock) counts as not checked
    (( age >= 0 && age < SKIP_SECONDS )) || return 1
    if (( age < 3600 )); then CHECKED_AGO="$(( age / 60 )) min"; else CHECKED_AGO="$(( age / 3600 )) h"; fi
}

# $1 with the home folder shown as ~, for messages.
tilde() {
    if [[ "$1" == "$HOME" || "$1" == "$HOME"/* ]]; then
        printf '%s' "~${1#"$HOME"}"
    else
        printf '%s' "$1"
    fi
}

# True if every named cfg key is set; otherwise says which are missing.
# $1 = what needs them (e.g. "static manager"), rest = the keys.
require_keys() {
    local what="$1" key
    local -a missing=()
    shift
    for key in "$@"; do
        [[ -n "${!key:-}" ]] || missing+=("$key")
    done
    (( ${#missing[@]} == 0 )) && return 0
    say "⚠ ${PROGRESS_LABEL:-}: $what needs ${missing[*]}, skipping"
    return 1
}

# The file the cfg's installed_file names, if it's still in folder $1: prints
# its full path, or nothing. Runs inside $(...), so it never prints a message.
find_installed() {
    [[ -n "${installed_file:-}" && -f "$1/$installed_file" ]] && printf '%s\n' "$1/$installed_file"
    return 0
}

# Save the item's state after a successful check or update; every mode uses
# this. Each key takes its value from the item being handled: what
# resolve_latest_asset found (cleared for every item), or the cfg variable of
# the same name (installed_file, iso_hash, checksum_file), which load_item
# reloads for every item and the caller updates first. Empty values aren't
# written, so an ISO cfg never gets current_version or etag.
save_update_metadata() {
    local cfg="$1" key value
    local -a pairs=()
    for key in "${SAVE_KEYS[@]}"; do
        case "$key" in
            last_checked)    value="$checked_at" ;;
            current_version) value="${latest_tag:-}" ;;
            content_length)  value="${remote_length:-}" ;;
            last_modified)   value="${remote_modified:-}" ;;
            asset_digest)    value="${remote_digest:-}" ;;
            etag)            value="${remote_etag:-}" ;;
            *)               value="${!key:-}" ;;
        esac
        [[ -n "$value" ]] && pairs+=("$key=$value")
    done
    save_state "$cfg" "${pairs[@]}"
}
