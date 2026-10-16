# shellcheck shell=bash disable=SC2154
# cfg.sh: reading and saving the cfg files. Loaded by load.sh.
# Cfg keys (manager, url, ...) are set by load_cfg through printf -v, and the
# per-item variables by process_item, so shellcheck can't see them assigned here.

# ---------------------------------------------------------------------------
# Config handling
# ---------------------------------------------------------------------------
# Every key a cfg may hold. load_cfg sets only these: any other name could
# overwrite one of the scripts' own variables (dir, name, HOME, PATH, ...).
CFG_KEYS=(
    manager repo repo_filename repo_regex allow_prereleases repo_url
    feed_url channel arch_key download_base url
    content_length last_modified current_version
    apworld_filename installed_file last_checked
    asset_digest etag
    checksum checksum_save download_suffix probe_days
    folder iso_hash checksum_file
)

load_cfg() {
    local cfg_file="$1"
    local line key value

    unset "${CFG_KEYS[@]}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
                value="${value//\\\"/\"}"
            fi
            if [[ " ${CFG_KEYS[*]} " == *" $key "* ]]; then
                printf -v "$key" '%s' "$value"
            else
                say "⚠ ${PROGRESS_LABEL:-}: unknown key '$key' in ${cfg_file##*/}, ignored"
            fi
        fi
    done < "$cfg_file"
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

update_cfg() {
    local cfg_file="$1"
    shift
    local pair key value escaped

    [[ -s "$cfg_file" && -n "$(tail -c1 "$cfg_file")" ]] && echo >> "$cfg_file"

    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"

        if [[ "$value" =~ [[:space:]\"] ]]; then
            value="\"${value//\"/\\\"}\""
        fi

        if grep -q "^${key}=" "$cfg_file"; then
            escaped="${value//\\/\\\\}"
            escaped="${escaped//&/\\&}"
            escaped="${escaped//|/\\|}"
            sed -i "s|^${key}=.*|${key}=${escaped}|" "$cfg_file"
        else
            echo "${key}=${value}" >> "$cfg_file"
        fi
    done
}

# The file the cfg's installed_file names, if it's still in folder $1: prints its
# full path, or nothing. Runs inside $(...), so it never prints a message.
find_installed() {
    [[ -n "${installed_file:-}" && -f "$1/$installed_file" ]] && printf '%s\n' "$1/$installed_file"
    return 0
}

# Cfg keys the scripts keep up to date themselves, in the order new ones are added.
SAVE_KEYS=(current_version last_checked content_length last_modified asset_digest etag
           installed_file iso_hash checksum_file)

# Save the item's state after a successful check or update; all three updaters
# use this. Each key takes its value from the item being handled: what
# resolve_latest_asset found (cleared for every item), or the cfg variable of the
# same name (installed_file, iso_hash, checksum_file), which load_cfg reloads for
# every item and the caller updates first. Empty values aren't written, so an
# ISO cfg never gets current_version or etag.
save_update_metadata() {
    local cfg="$1" key value
    local -a pairs=()
    for key in "${SAVE_KEYS[@]}"; do
        case "$key" in
            last_checked)    value="$today" ;;
            current_version) value="${latest_tag:-}" ;;
            content_length)  value="${remote_length:-}" ;;
            last_modified)   value="${remote_modified:-}" ;;
            asset_digest)    value="${remote_digest:-}" ;;
            etag)            value="${remote_etag:-}" ;;
            *)               value="${!key:-}" ;;
        esac
        [[ -n "$value" ]] && pairs+=("$key=$value")
    done
    update_cfg "$cfg" "${pairs[@]}"
}
