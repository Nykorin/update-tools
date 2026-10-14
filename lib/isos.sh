# shellcheck shell=bash disable=SC2154,SC2034
# isos.sh: the ISO updater (checksums, free space, the folder= key): its
# prepare_dir and process_item, and their helpers. main.sh loads it for -m iso,
# in that mode's own subshell, so the function names don't clash with the other
# modules. It reads (SC2154) and sets (SC2034) variables that main.sh and the
# shared libraries own.

# "<algo> <hash>" for file $2 in checksum text $1. Reads GNU lines ("hash  name",
# "hash *name", "hash  ./name") and BSD lines ("SHA256 (name) = hash"), matching
# on the file name alone (Ultramarine lists build paths); sha512 wins over sha256,
# and md5/sha1 entries are ignored.
checksum_for() {
    awk -v want="$2" '
        { name = ""; hash = "" }
        /^[A-Za-z0-9-]+ \(.*\) = [0-9a-fA-F]+$/ {
            name = $0; sub(/^[^(]*\(/, "", name); sub(/\) = [0-9a-fA-F]+$/, "", name); hash = $NF }
        /^[0-9a-fA-F]+ [ *]/ {
            hash = $1; name = $0; sub(/^[0-9a-fA-F]+ [ *]/, "", name); sub(/^ ?\*?(\.\/)?/, "", name) }
        { sub(/^.*\//, "", name) }
        hash != "" && name == want {
            n = length(hash); if ((n == 64 || n == 128) && n > best) { best = n; h = hash } }
        END { if (best) print (best == 128 ? "sha512" : "sha256"), tolower(h) }' <<<"$1"
}

# Fetches the checksum for asset_name: sets sum_url, sum_text, algo and want
# (process_item's locals). A relative checksum is next to the ISO; for static, next
# to the cfg's URL (Garuda's latest.iso.sha256 sits beside latest.iso, not where it
# redirects). Returns 1 to skip the item.
fetch_checksum() {
    local dir_url sum found glob_rc
    if [[ "$manager" == static ]]; then
        dir_url="${url%/*}/"
    else
        dir_url="${asset_url%"${download_suffix:-}"}"
        dir_url="${dir_url%/*}/"
    fi
    sum="$checksum"; sum="${sum//\{iso\}/$asset_name}"
    [[ "$sum" == *://* ]] || sum="$dir_url$sum"
    if [[ "$sum" == *'*'* || "$sum" == *'['* ]]; then
        found=$(resolve_glob_url "$sum"); glob_rc=$?
        if (( glob_rc == 2 )); then
            say "⚠ ${PROGRESS_LABEL:-}: could not list $found, skipping"
            return 1
        elif (( glob_rc )); then
            say "⚠ ${PROGRESS_LABEL:-}: no checksum file matches ${sum##*/}, skipping"
            return 1
        fi
        sum="$found"
    fi
    sum_url="$sum"

    debug "checksum file: $sum_url"
    if ! sum_text=$(curl -fsL "${CURL_META[@]}" "$sum_url"); then
        say "⚠ $name: could not fetch checksum file $sum_url, skipping"
        return 1
    fi
    read -r algo want <<<"$(checksum_for "$sum_text" "$asset_name")"
    if [[ -z "${want:-}" ]]; then
        say "⚠ $name: $asset_name isn't listed in ${sum_url##*/}, skipping"
        return 1
    fi
    debug "expected $algo ${want:0:16}…"
}

# One cfg: check it, and update it if needed.
process_item() {
    local i="$1"
    local sum_text algo want got size avail sum_name
    local rc sum_url new_file new_name target
    cfg_file="${cfg_files[$i]}"
    name="${cfg_file##*/}"
    name="${name%".$ITEM_EXT.cfg"}"

    PROGRESS_DONE=$i
    PROGRESS_LABEL="$name"
    STATUS=""
    block_redraw

    load_cfg "$cfg_file"
    debug "cfg: manager=${manager:-?} version=${current_version:-none} installed_file=${installed_file:-none} last_checked=${last_checked:-never}"
    debug "folder: ${folder:-none}"
    # folder= is relative to the root, so -r still works; it may not leave it
    folder="${folder:-}"; folder="${folder%/}"
    if [[ -z "$folder" || "$folder" == /* || "/$folder/" == */../* ]]; then
        say "⚠ $name: folder must be a path inside $ISO_DIR, like Linux/Fedora/Fedora, skipping"
        return 0
    fi
    dir="$ISO_DIR/$folder"
    # every ISO is verified; the manager checks its own keys
    require_keys "an ISO cfg" checksum || return 0

    installed_path=$(find_installed "$dir")
    if [[ -n "$installed_path" ]]; then
        debug "installed file: ${installed_path##*/}"
    else
        debug "not installed yet: installing it"
    fi

    if [[ "$force" == false && -n "$installed_path" && "${last_checked:-}" == "$today" ]]; then
        status_final "✓ already checked today (${current_version:-$installed_file})"
        return 0
    fi

    # a 304 has no download URL, so ask for the full list when installing; -f always does
    # (a static item's etag is the server's file ETag, which it still needs to compare)
    if [[ "${manager:-}" == github && ( "$force" == true || -z "$installed_path" ) ]]; then
        etag=""
        if [[ -n "$installed_path" ]]; then
            debug "full release list requested (-f)"
        else
            debug "full release list requested (not installed yet)"
        fi
    fi
    resolve_latest_asset; rc=$?
    if (( rc == 2 )); then
        # every further GitHub request would fail the same way
        say "  ✗ stopping, $(( ${#cfg_files[@]} - i - 1 )) more $ITEM_EXT(s) not checked"
        return 2
    elif (( rc )); then
        return 0
    fi

    # nothing newer on the server, but the installed file is gone: nothing to download
    if (( remote_unchanged )) && [[ -z "$installed_path" ]]; then
        say "⚠ $name: ${installed_file:-its file} is missing and the server has nothing newer, skipping"
        return 0
    fi
    # nothing newer on the server (an old ISO's checksum file may be gone with it)
    if (( remote_unchanged )); then
        report_up_to_date
        return 0
    fi
    # ISOs are compared, and later verified, by checksum
    fetch_checksum || return 0
    if [[ -n "$installed_path" ]] && is_up_to_date "$installed_path"; then
        report_up_to_date
        return 0
    fi

    # -c: report it, download and write nothing
    if [[ "$check_only" == true ]]; then
        status_final "⬆ update available: $(shown_version "$asset_name")"
        return 0
    fi

    mkdir -p "$dir"
    # static already has the size from its lookup
    size="${remote_length:-}"
    [[ -n "$size" ]] || size=$(curl -fsIL "${CURL_META[@]}" "$asset_url" | awk 'tolower($1) == "content-length:" { v = $2 } END { sub(/\r/, "", v); print v }')
    avail=$(df --output=avail -B1 "$dir" | tail -n 1)
    debug "size ${size:-unknown} bytes, $(( avail >> 20 )) MiB free"
    # keep 256 MiB spare; the old ISO stays until the new one verifies
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size + 268435456 > avail )); then
        say "⚠ $name: not enough space for $asset_name ($(( size >> 20 )) MiB + 256 MiB spare needed, $(( avail >> 20 )) MiB free), skipping"
        return 0
    fi

    if [[ -n "$installed_path" ]]; then
        status "⬆ updating"
    else
        status "⬇ installing"
    fi

    # next to the ISO (same filesystem, so installing is a rename), hidden and not
    # ending in .iso so Ventoy never lists a partial download
    tmp_download="$dir/.$asset_name.part"

    curl_takeover
    if ! curl_run -fL "${CURL_DL[@]}" --progress-bar "$asset_url" -o "$tmp_download"; then
        curl_abandon
        say "  ✗ Failed to download update for $name"
        rm -f "$tmp_download"
        return 0
    fi
    curl_handback
    debug "downloaded to $tmp_download"

    status "🔍 verifying $asset_name"
    got=$(hash_file "$algo" "$tmp_download")
    debug "downloaded file's $algo: ${got:0:16}…"
    if [[ "$got" != "$want" ]]; then
        say "  ✗ $name: checksum mismatch for $asset_name, download deleted"
        rm -f "$tmp_download"
        return 0
    fi
    iso_hash="$algo:$want"

    # the checksum was looked up under the upstream name; this is only where it lands
    pick_name "$asset_name"
    target="$dir/$new_name"

    new_file="$tmp_download"
    # the installed version (and a stray file already using the new name) waits in
    # .tmp until the new one is in place
    if ! set_aside "$installed_path" "$target"; then
        say "  ✗ $name: could not move the old version aside, nothing changed"
        rm -f "$tmp_download"
        return 0
    fi

    # a rename on one disk; should it still fail, put the old version back
    if ! mv -f "$new_file" "$target"; then
        restore_previous
        say "  ✗ $name: could not install ${target##*/}, kept the old one"
        rm -f "$tmp_download"
        return 0
    fi
    [[ -n "$ITEM_MODE" ]] && chmod "$ITEM_MODE" "$target"
    rm -f "$tmp_download"
    debug "installed as ${target##*/}"
    drop_previous

    sum_name="${checksum_save:-${sum_url##*/}}"
    sum_name="${sum_name//\{iso\}/$asset_name}"
    printf '%s\n' "$sum_text" > "$dir/$sum_name"
    # the old checksum file goes once the new one is saved
    [[ -n "${checksum_file:-}" && "$checksum_file" != "$sum_name" ]] && rm -f "$dir/$checksum_file"
    checksum_file="$sum_name"

    installed_file="$new_name"
    save_update_metadata "$cfg_file"
    status_final "✓ updated to $(shown_version "$installed_file")"
}

prepare_dir() {
    # process_item points dir at each ISO's folder, so keep the root
    ISO_DIR="$dir"
    # old versions wait here during an update (as .previous, which Ventoy doesn't list)
    TMP_DIR="$dir/.tmp"
    # left over from a run that was killed outright (Ctrl+C cleans up after itself):
    # an old version goes back, a half-downloaded ISO goes
    recover_previous
    find "$dir" -mindepth 1 -name '.*.iso.part' -type f -delete
}
