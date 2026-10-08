#!/usr/bin/env bash
# update-apworlds.sh
#
# Updates Archipelago custom worlds (.apworld files). Adapted from
# update-appimages.sh: same github/gitlab/static managers, per-item .cfg
# files and .old/ backups, minus the extraction / desktop-entry / icon logic.
#
# Layout, all under $WORLDS_DIR:
#   <module>.apworld   installed worlds
#   .cfg/              one <label>.apworld.cfg per world
#   .old/              the previous copy of anything that got replaced
#   .tmp/              in-progress downloads (same filesystem as the target,
#                      so the final mv is an atomic rename)
# Archipelago skips every entry starting with "." or "_" when it indexes
# custom_worlds (worlds/__init__.py), so the dot-folders are invisible to it.
#
# <label> in <label>.apworld.cfg is just a name for the config. Several
# configs can point at the same repo (one per world it hosts); each repo's
# release list is fetched once per run and shared between them.
#
# Config keys (plain KEY=VALUE lines, never sourced — see load_cfg):
#   manager=github|gitlab|static
#   github:  repo=owner/name
#            repo_filename=PATTERN   glob where * is the only wildcard; must
#                                    match the whole asset name
#            allow_prereleases=auto|false|true   (default: auto)
#                false  newest stable release only
#                true   newest release of any kind
#                auto   newest stable release, else newest pre-release
#   gitlab:  repo_url=https://gitlab.com/group/project
#            repo_filename=PATTERN   matched against the release link name
#   static:  url=https://example.com/path/world.apworld
#   any:     install_name=foo.apworld   force the installed filename
#   written by this script: current_version, installed_file, last_checked,
#                           content_length, last_modified (static only)
#
# last_checked: the date (YYYY-MM-DD) of the last successful check. A world
# that was already checked today is skipped without any network request;
# pass -f/--force to check everything anyway. A failed check or download
# doesn't count, so it is retried on the next run.
#
# Rate limits: if GitHub/GitLab answer 429 (or a 403 that says "rate limit"),
# the script stops right there with exit code 1 instead of burning through
# the rest of the list. Everything finished before that is already saved.
#
# Installed filename: Archipelago imports a world as worlds.<filename stem>,
# so the stem must equal the top-level folder inside the zip. Release assets
# are often versioned (foo-v1.2.apworld), so the name is taken from the zip's
# contents unless install_name is set. A warning is printed if they disagree.
#
# Optional: export GITHUB_TOKEN to lift the 60 requests/hour API limit.
set -uo pipefail

force=false
case "${1:-}" in
    "")           ;;
    -f|--force)   force=true ;;
    *)            echo "Usage: ${0##*/} [-f|--force]" >&2; exit 2 ;;
esac
today=$(date +%F)

WORLDS_DIR="${WORLDS_DIR:-/mnt/games_rando/Archipelago/custom_worlds}"
CFG_DIR="$WORLDS_DIR/.cfg"
OLD_DIR="$WORLDS_DIR/.old"
TMP_DIR="$WORLDS_DIR/.tmp"

for dep in curl jq unzip; do
    command -v "$dep" &>/dev/null || { echo "ERROR: required command not found: $dep" >&2; exit 1; }
done

# Simple URL-encoder (enough for GitLab project paths)
urlencode() {
    printf '%s' "$1" | sed \
        -e 's|/|%2F|g' \
        -e 's| |%20|g' \
        -e 's|\[|%5B|g' \
        -e 's|\]|%5D|g' \
        -e 's|@|%40|g' \
        -e 's|:|%3A|g'
}

backup_world() {
    local world_file="$1"
    mkdir -p "$OLD_DIR"
    mv "$world_file" "$OLD_DIR/${world_file##*/}"
}

# Turn a filename glob (only * is special) into an anchored regex for jq
glob_to_regex() {
    local p="$1"
    p="${p//./\\.}"
    p="${p//\*/.*}"
    printf '^%s$' "$p"
}

# GET a URL once per run; later calls for the same URL reuse the result. A
# failed request is cached as an empty string. The result is left in the
# global $release_json (not printed) because the cache has to be written in
# the current shell — a $(...) call would lose it with its subshell.
# Exits the whole script if the host says we are rate-limited.
declare -A JSON_CACHE=()
release_json=""
fetch_json() {
    local url="$1" response status body host
    local -a curl_args=(-sSL -w $'\n%{http_code}')
    if [[ ! -v "JSON_CACHE[$url]" ]]; then
        [[ "$url" == https://api.github.com/* && -n "${GITHUB_TOKEN:-}" ]] && \
            curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
        response=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || response=$'\n000'
        status="${response##*$'\n'}"
        body="${response%$'\n'*}"

        if [[ "$status" == 429 ]] || [[ "$status" == 403 && "${body,,}" == *"rate limit"* ]]; then
            host="${url#https://}"
            host="${host%%/*}"
            echo "✗ Rate-limited by $host, stopping here. Finished worlds are saved; try again later." >&2
            [[ "$host" == api.github.com && -z "${GITHUB_TOKEN:-}" ]] && \
                echo "  (exporting GITHUB_TOKEN raises GitHub's limit from 60 to 5000 requests/hour)" >&2
            exit 1
        fi

        if [[ "$status" == 2* ]]; then
            JSON_CACHE[$url]="$body"
        else
            JSON_CACHE[$url]=""
        fi
    fi
    release_json="${JSON_CACHE[$url]}"
}

# Print "<tag>\t<url>" for the newest release that has an asset matching the
# regex (not merely the newest release — repos hosting several worlds may
# tag them separately). $3 = true|false: whether pre-releases are eligible.
pick_github_asset() {
    local json="$1" regex="$2" include_pre="$3"
    jq -r --arg pat "$regex" --argjson pre "$include_pre" '
        if type != "array" then empty else
            [ .[]
              | select((.draft // false) | not)
              | select($pre or ((.prerelease // false) | not))
              | . as $r
              | ([ $r.assets[] | select(.name | test($pat)) ][0]) as $a
              | select($a != null)
              | [$r.tag_name, $a.browser_download_url] ]
            | (.[0] // empty) | @tsv
        end' <<<"$json" 2>/dev/null
}

pick_gitlab_asset() {
    local json="$1" regex="$2"
    jq -r --arg pat "$regex" '
        if type != "array" then empty else
            [ .[]
              | . as $r
              | ([ ($r.assets.links // [])[] | select(.name | test($pat)) ][0]) as $a
              | select($a != null)
              | [$r.tag_name, ($a.direct_asset_url // $a.url)] ]
            | (.[0] // empty) | @tsv
        end' <<<"$json" 2>/dev/null
}

# Update one or more key=value lines in a .cfg file using sed
update_cfg() {
    local cfg_file="$1"
    shift
    local pair key value escaped

    # Don't glue a new line onto a last line that lacks its newline
    [[ -s "$cfg_file" && -n "$(tail -c1 "$cfg_file")" ]] && echo >> "$cfg_file"

    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"

        # Quote the value if it contains spaces or special characters
        if [[ "$value" =~ [[:space:]\"] ]]; then
            value="\"${value//\"/\\\"}\""
        fi

        if grep -q "^${key}=" "$cfg_file"; then
            # Escape \, &, and | for sed's replacement text
            escaped="${value//\\/\\\\}"
            escaped="${escaped//&/\\&}"
            escaped="${escaped//|/\\|}"
            sed -i "s|^${key}=.*|${key}=${escaped}|" "$cfg_file"
        else
            echo "${key}=${value}" >> "$cfg_file"
        fi
    done
}

# Safe config loader — never executes the file
load_cfg() {
    local cfg_file="$1"
    local line key value

    unset manager repo repo_filename allow_prereleases repo_url url \
          install_name installed_file content_length last_modified \
          current_version last_checked

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Strip one layer of surrounding double quotes and unescape \"
            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
                value="${value//\\\"/\"}"
            fi
            printf -v "$key" '%s' "$value"
        fi
    done < "$cfg_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$CFG_DIR" "$OLD_DIR" "$TMP_DIR"

for cfg_file in "$CFG_DIR"/*.apworld.cfg; do
    [[ -f "$cfg_file" ]] || continue

    world_name="${cfg_file##*/}"
    world_name="${world_name%.apworld.cfg}"

    load_cfg "$cfg_file"

    installed_path=""
    if [[ -n "${installed_file:-}" && -f "$WORLDS_DIR/$installed_file" ]]; then
        installed_path="$WORLDS_DIR/$installed_file"
    fi

    if [[ "$force" == false && -n "$installed_path" && "${last_checked:-}" == "$today" ]]; then
        echo "✓ $world_name already checked today (${current_version:-unknown})"
        continue
    fi

    remote_length=""
    remote_modified=""
    latest_tag=""
    asset_url=""
    asset_name=""
    result=""

    case "${manager:-}" in
        github)
            if [[ -z "${repo:-}" || -z "${repo_filename:-}" ]]; then
                echo "⚠ $world_name: github manager needs repo and repo_filename, skipping"
                continue
            fi
            fetch_json "https://api.github.com/repos/${repo}/releases"
            if [[ -z "$release_json" ]]; then
                echo "⚠ $world_name: could not fetch releases for $repo, skipping"
                continue
            fi
            regex=$(glob_to_regex "$repo_filename")
            case "${allow_prereleases:-auto}" in
                false) result=$(pick_github_asset "$release_json" "$regex" false) ;;
                true)  result=$(pick_github_asset "$release_json" "$regex" true) ;;
                auto)  result=$(pick_github_asset "$release_json" "$regex" false)
                       [[ -z "$result" ]] && result=$(pick_github_asset "$release_json" "$regex" true) ;;
                *)
                    echo "⚠ $world_name: allow_prereleases must be auto, false or true (got '${allow_prereleases}'), skipping"
                    continue
                    ;;
            esac
            IFS=$'\t' read -r latest_tag asset_url <<<"$result"
            asset_name="${asset_url##*/}"
            ;;
        gitlab)
            if [[ -z "${repo_url:-}" || -z "${repo_filename:-}" ]]; then
                echo "⚠ $world_name: gitlab manager needs repo_url and repo_filename, skipping"
                continue
            fi
            project_path="${repo_url#https://gitlab.com/}"
            encoded_path=$(urlencode "$project_path")

            fetch_json "https://gitlab.com/api/v4/projects/${encoded_path}/releases"
            if [[ -z "$release_json" ]]; then
                echo "⚠ $world_name: could not fetch releases for $repo_url, skipping"
                continue
            fi
            result=$(pick_gitlab_asset "$release_json" "$(glob_to_regex "$repo_filename")")
            IFS=$'\t' read -r latest_tag asset_url <<<"$result"
            asset_name="${asset_url##*/}"
            ;;
        static)
            if [[ -z "${url:-}" ]]; then
                echo "⚠ $world_name: static manager needs url, skipping"
                continue
            fi
            # Single curl: headers + final effective URL
            mapfile -t curl_out < <(curl -sIL -w '\n%{url_effective}' "$url")
            asset_url="${curl_out[-1]}"
            unset 'curl_out[-1]'
            # One header per line: joining with spaces would put the whole
            # response on one line and awk would read the 302's status code
            headers=$(printf '%s\n' "${curl_out[@]}")

            remote_length=$(awk 'tolower($0) ~ /content-length/{v=$2} END{gsub(/\r/,"",v); print v}' <<<"$headers")
            remote_modified=$(awk 'tolower($0) ~ /last-modified/{sub(/^[^:]*:[ ]*/,""); v=$0} END{gsub(/\r/,"",v); print v}' <<<"$headers")

            [[ -z "$asset_url" ]] && asset_url="$url"
            asset_name="${asset_url##*/}"
            latest_tag="static-$remote_length"
            ;;
        *)
            echo "⚠ $world_name: unknown or missing manager '${manager:-}', skipping"
            continue
            ;;
    esac

    # Unified "up to date" check (a world that isn't installed always installs)
    if [[ -n "$installed_path" ]]; then
        if [[ "$manager" == "static" ]]; then
            if [[ -n "$remote_length" && "$remote_length" == "${content_length:-}" && \
                  "$remote_modified" == "${last_modified:-}" ]]; then
                echo "✓ $world_name is up to date (unchanged)"
                update_cfg "$cfg_file" "last_checked=$today"
                continue
            fi
        elif [[ "$latest_tag" == "${current_version:-}" ]]; then
            echo "✓ $world_name is up to date ($current_version)"
            update_cfg "$cfg_file" "last_checked=$today"
            continue
        fi
    fi

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        echo "⚠ $world_name: no matching release asset found, skipping"
        continue
    fi

    if [[ -n "$installed_path" ]]; then
        echo "⬆ Updating $world_name..."
    else
        echo "⬇ Installing $world_name..."
    fi
    tmp_download="$(mktemp -p "$TMP_DIR" "download.XXXXXX")"

    if ! curl -fL --progress-bar "$asset_url" -o "$tmp_download"; then
        echo "  ✗ Failed to download $world_name"
        rm -f "$tmp_download"
        continue
    fi

    if ! zip_listing=$(unzip -Z1 "$tmp_download" 2>/dev/null); then
        echo "  ✗ $world_name: download is not a valid .apworld (zip), keeping current version"
        rm -f "$tmp_download"
        continue
    fi
    mapfile -t top_dirs < <(awk -F/ 'NF>1 && $1!="" {print $1}' <<<"$zip_listing" | sort -u)

    if [[ -n "${install_name:-}" ]]; then
        target_name="$install_name"
    elif (( ${#top_dirs[@]} == 1 )); then
        target_name="${top_dirs[0]}.apworld"
    else
        target_name="$asset_name"
    fi

    if (( ${#top_dirs[@]} != 1 )) || [[ "${target_name%.apworld}" != "${top_dirs[0]}" ]]; then
        echo "  ⚠ $target_name doesn't match the module folder inside the zip (${top_dirs[*]:-none});" \
             "Archipelago may fail to load it"
    fi

    target="$WORLDS_DIR/$target_name"
    [[ -f "$target" ]] && backup_world "$target"
    [[ -n "$installed_path" && "$installed_path" != "$target" && -f "$installed_path" ]] && \
        backup_world "$installed_path"

    mv "$tmp_download" "$target"
    chmod 644 "$target"

    # Persist new metadata
    if [[ "$manager" == "static" ]]; then
        update_cfg "$cfg_file" \
            "current_version=$latest_tag" \
            "installed_file=$target_name" \
            "last_checked=$today" \
            "content_length=$remote_length" \
            "last_modified=$remote_modified"
    else
        update_cfg "$cfg_file" \
            "current_version=$latest_tag" \
            "installed_file=$target_name" \
            "last_checked=$today"
    fi

    echo "  ✓ $world_name updated to $latest_tag ($target_name)"
done
