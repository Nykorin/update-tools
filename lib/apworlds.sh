# shellcheck shell=bash disable=SC2154,SC2034
# apworlds.sh: the Archipelago world updater (bundles): its prepare_dir, the
# process_item hooks it needs, and their helpers. main.sh loads it for -m apw,
# in that mode's own subshell, so the function names don't clash with the other
# modules. It reads (SC2154) and sets (SC2034) variables that main.sh and the
# shared libraries own.

unbundle_apworld() {
    local pattern="${apworld_filename:-*.apworld}"
    local entry base member extracted list
    local -a matches=()

    grep -qi '\.apworld$' <<<"$zip_listing" || return 0

    while IFS= read -r entry; do
        [[ "$entry" == */ ]] && continue
        base="${entry##*/}"
        # shellcheck disable=SC2053
        [[ "${base,,}" == ${pattern,,} ]] && matches+=("$entry")
    done <<<"$zip_listing"

    if (( ${#matches[@]} == 0 )); then
        say "  ✗ $name: no .apworld matching '$pattern' inside the release zip"
        return 1
    elif (( ${#matches[@]} > 1 )); then
        # one say, so the list is printed above the status block, not into it
        printf -v list '\n      %s' "${matches[@]##*/}"
        say "  ✗ $name: release zip holds several .apworld files, set apworld_filename:$list"
        return 1
    fi

    member="${matches[0]}"
    extracted="$TMP_DIR/extracted.apworld"
    if ! extract_member "$tmp_download" "$member" "$extracted"; then
        say "  ✗ $name: could not extract $member"
        rm -f "$extracted"
        return 1
    fi

    rm -f "$tmp_download"
    tmp_download="$extracted"
    # .apworld files are themselves zips
    if ! zip_listing=$(unzip -Z1 "$tmp_download" 2>/dev/null); then
        say "  ✗ $name: extracted file is not a valid .apworld"
        return 1
    fi
    asset_name="${member##*/}"
    debug "bundle member: $member"
    status "📦 extracted $asset_name"
}

ITEM_LOCALS=(zip_listing)

# extract_member picks the unpacker by extension; every world is a zip
item_stage() {
    tmp_download="$TMP_DIR/download.zip"
}

# A world must be a zip; a bundle's .apworld is extracted and used instead. The
# name stays the upstream one: Archipelago reports a world whose name doesn't
# match its module.
item_validate() {
    if ! zip_listing=$(unzip -Z1 "$tmp_download" 2>/dev/null); then
        say "  ✗ $name: download is not a valid .apworld (zip)"
        return 1
    fi
    unbundle_apworld
}


prepare_dir() {
    TMP_DIR="$dir/.tmp"
    mkdir -p "$TMP_DIR"
    # left over from an interrupted earlier run: an old version goes back first
    recover_previous
    rm -f "$TMP_DIR"/download.* "$TMP_DIR"/extracted.*
}
