# shellcheck shell=bash disable=SC2154,SC2034
# isos.sh: the ISO updater (checksums, free space, the folder= key): its
# prepare_dir, the process_item hooks it needs, and their helpers. main.sh loads
# it for -m iso, in that mode's own subshell, so the function names don't clash
# with the other modules. It reads (SC2154) and sets (SC2034) variables that
# main.sh and the shared libraries own.

# "<algo> <hash>" for file $2 in checksum text $1. Reads GNU lines
# ("hash  name", "hash *name", "hash  ./name") and BSD lines
# ("SHA256 (name) = hash"), matching on the file name alone (Ultramarine lists
# build paths); sha512 wins over sha256, and md5/sha1 entries are ignored.
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

# The item_prepare_check hook: ISOs are compared, and later verified, by
# checksum. Fetches the checksum for asset_name: sets sum_url, sum_text, algo
# and want (ITEM_LOCALS). A relative checksum is next to the ISO; for static,
# next to the cfg's URL (Garuda's latest.iso.sha256 sits beside latest.iso, not
# where it redirects). Returns 1 to skip the item.
item_prepare_check() {
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

ITEM_LOCALS=(sum_text sum_url algo want got size avail sum_name)

# folder= is relative to the root, so -r still works; it may not leave it. Every
# ISO is verified, so checksum is required; the manager checks its own keys.
item_setup() {
    debug "folder: ${folder:-none}"
    folder="${folder:-}"; folder="${folder%/}"
    if [[ -z "$folder" || "$folder" == /* || "/$folder/" == */../* ]]; then
        say "⚠ $name: folder must be a path inside $ISO_DIR, like Linux/Fedora/Fedora, skipping"
        return 1
    fi
    dir="$ISO_DIR/$folder"
    require_keys "an ISO cfg" checksum
}

# keep 256 MiB spare; the old ISO stays until the new one verifies
item_preflight() {
    mkdir -p "$dir"
    # static already has the size from its lookup
    size="${remote_length:-}"
    [[ -n "$size" ]] || size=$(curl -fsIL "${CURL_META[@]}" "$asset_url" | awk 'tolower($1) == "content-length:" { v = $2 } END { sub(/\r/, "", v); print v }')
    avail=$(df --output=avail -B1 "$dir" | tail -n 1)
    debug "size ${size:-unknown} bytes, $(( avail >> 20 )) MiB free"
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size + 268435456 > avail )); then
        say "⚠ $name: not enough space for $asset_name ($(( size >> 20 )) MiB + 256 MiB spare needed, $(( avail >> 20 )) MiB free), skipping"
        return 1
    fi
}

# next to the ISO (same filesystem, so installing is a rename), hidden and not
# ending in .iso so Ventoy never lists a partial download
item_stage() {
    tmp_download="$dir/.$asset_name.part"
}

# The checksum was looked up under the upstream name, which the install name
# (pick_name) may differ from.
item_validate() {
    status "🔍 verifying $asset_name"
    got=$(hash_file "$algo" "$tmp_download")
    debug "downloaded file's $algo: ${got:0:16}…"
    if [[ "$got" != "$want" ]]; then
        say "  ✗ $name: checksum mismatch for $asset_name, download deleted"
        return 1
    fi
    iso_hash="$algo:$want"
}

# the upstream checksum file next to the ISO; the old one goes once it's saved
item_extras() {
    sum_name="${checksum_save:-${sum_url##*/}}"
    sum_name="${sum_name//\{iso\}/$asset_name}"
    printf '%s\n' "$sum_text" > "$dir/$sum_name"
    [[ -n "${checksum_file:-}" && "$checksum_file" != "$sum_name" ]] && rm -f "$dir/$checksum_file"
    checksum_file="$sum_name"
}


prepare_dir() {
    # process_item points dir at each ISO's folder, so keep the root
    ISO_DIR="$dir"
    # old versions wait here during an update (as .previous, which Ventoy
    # doesn't list)
    TMP_DIR="$dir/.tmp"
    # left over from a run that was killed outright (Ctrl+C cleans up after
    # itself): an old version goes back, a half-downloaded ISO goes (.NAME.part:
    # an upstream name may not end in .iso)
    recover_previous
    find "$dir" -mindepth 1 -name '.*.part' -type f -delete
}
