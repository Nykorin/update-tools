# shellcheck shell=bash disable=SC2034
# menu.sh: update-tools' menu, shown without -m on a terminal when fzf is
# installed. Step 1 picks the kinds; step 2, for each kind, either checks all
# its items or picks single ones; after the check, the updates found are
# offered for download (all marked). The runs themselves are the usual
# run_modes, limited through MODE_ITEMS. Loaded by load.sh. It sets (SC2034)
# variables that main.sh reads.

menu_available() { [[ -t 0 && -t 1 ]] && command -v fzf &>/dev/null; }

# fzf with the menu's look, inline below the prompt so the scrollback stays.
# Lines are tab-separated: field 1 is what's returned, the rest is shown.
menu_fzf() {
    fzf --multi --delimiter=$'\t' --with-nth=2.. --layout=reverse \
        --height='~60%' --border=rounded --info=inline-right "$@"
}

# What a cfg shows in step 2: the version (the installed file for static
# items, whose version is long), and when it was last checked.
menu_item_line() {
    local f="$1" name info
    name="${f##*/}"; name="${name%.json}"
    info=$(jq -r '.state // {} |
        [ (if (.current_version // "" | startswith("static-")) or .current_version == null
           then .installed_file // "not installed" else .current_version end),
          (.last_checked // "never" | sub("T"; " ")) ] | @tsv' "$f" 2>/dev/null) ||
        info=$'(not a valid cfg)\t'
    printf '%s\t%-28s %-44s %s\n' "$name" "$name" "${info%%$'\t'*}" "checked ${info#*$'\t'}"
}

run_menu() {
    local m line rc f n kind
    local -a avail=() lines=() picks=() choice=() check=() runs=()
    local header="" unavailable=""

    # step 1 lines: every mode whose folder is there; the rest are named in
    # the header, since fzf can't grey out a line
    for m in app apw iso; do
        ITEM_TYPE="$m"; item_settings
        if [[ -z "$DEFAULT_DIR" ]]; then
            unavailable+=$'\n'"  $ITEM_TITLE: no $DIR_KEY in $(tilde "$SETTINGS_FILE")"
        elif [[ ! -d "$DEFAULT_DIR" ]]; then
            unavailable+=$'\n'"  $ITEM_TITLE: $(tilde "$DEFAULT_DIR") not found.${NOT_FOUND_HINT:+ $NOT_FOUND_HINT}"
        else
            n=$(find "$DEFAULT_DIR/.update-tools/db" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
            f=items; (( n == 1 )) && f=item
            avail+=("$(printf '%s\t%-20s %4d %-5s   %s' "$m" "$ITEM_TITLE" "$n" "$f" "$(tilde "$DEFAULT_DIR")")")
        fi
    done
    if (( ${#avail[@]} == 0 )); then
        printf '%s\n' "⚠ nothing to update:${unavailable}" >&2
        return 1
    fi
    header="What to update  (Tab: mark, Enter: go, Esc: quit)${unavailable:+$'\n'Not available:$unavailable}"

    while :; do
        picks=() check=() runs=()
        MODE_ITEMS=()
        mapfile -t picks < <(printf '%s\n' "${avail[@]}" | menu_fzf --header="$header" | cut -f1)
        (( ${#picks[@]} )) || return 0

        # step 2, per kind: all of it (checked first), or single items; Esc
        # goes back to step 1
        for m in app apw iso; do
            [[ " ${picks[*]} " == *" $m "* ]] || continue
            ITEM_TYPE="$m"; item_settings
            lines=("$(printf '*\t* check all for updates, then choose what to download')")
            for f in "$DEFAULT_DIR/.update-tools/db"/*.json; do
                [[ -f "$f" ]] && lines+=("$(menu_item_line "$f")")
            done
            mapfile -t choice < <(printf '%s\n' "${lines[@]}" |
                menu_fzf --header="$ITEM_TITLE  (Tab: mark, Enter: go, Esc: back)" | cut -f1)
            (( ${#choice[@]} )) || continue 2
            if [[ " ${choice[*]} " == *" * "* ]]; then
                check+=("$m")
            else
                runs+=("$m")
                printf -v "MODE_ITEMS[$m]" '%s\n' "${choice[@]}"
            fi
        done
        break
    done

    ALWAYS_HEADINGS=1
    rc=0
    # the check: nothing is downloaded or written; what it finds is offered
    # below on a cleared screen, with each kind's summary and the log of the
    # check (with -c, the check is all there is, and stays on screen)
    if (( ${#check[@]} )); then
        local log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/update-tools" summary="" t prev=""
        mkdir -p "$log_dir"
        RUN_LOG="$log_dir/check.log"
        : > "$RUN_LOG"
        AVAILABLE_FILE=$(mktemp) SUMMARY_FILE=$(mktemp)
        # shellcheck disable=SC2064  # the files' names now, not at exit
        trap "rm -f '$AVAILABLE_FILE' '$SUMMARY_FILE'" EXIT
        local saved_check="$check_only"
        check_only=true HEADING_NOTE="checking for updates"
        run_modes "${check[@]}" || rc=1
        check_only="$saved_check" HEADING_NOTE=""

        # one line per kind: its summary lines joined
        while IFS=$'\t' read -r t line; do
            if [[ "$t" == "$prev" ]]; then summary+=" · $line"; else summary+=$'\n'"$t: $line"; fi
            prev="$t"
        done < "$SUMMARY_FILE"
        summary+=$'\n'"Log of the check: $(tilde "$RUN_LOG")"
        rm -f "$SUMMARY_FILE"; SUMMARY_FILE=""
        RUN_LOG=""

        lines=()
        while IFS=$'\t' read -r m n line; do
            case "$m" in app) kind="AppImage" ;; apw) kind="world" ;; iso) kind="ISO" ;; esac
            lines+=("$(printf '%s\t%s\t%-9s %-28s %s' "$m" "$n" "$kind" "$n" "$line")")
        done < "$AVAILABLE_FILE"
        rm -f "$AVAILABLE_FILE"; AVAILABLE_FILE=""

        if [[ "$check_only" != true ]]; then
            # the check is in the log now
            printf '\033[H\033[2J'
            n=0
            if (( ${#lines[@]} )); then
                while IFS=$'\t' read -r m f; do
                    [[ -n "$m" ]] || continue
                    [[ " ${runs[*]} " == *" $m "* ]] || runs+=("$m")
                    MODE_ITEMS["$m"]+="$f"$'\n'
                    (( ++n ))
                done < <(printf '%s\n' "${lines[@]}" |
                    menu_fzf --with-nth=3.. --bind 'load:select-all' \
                        --header="Updates to download  (Tab: unmark, Enter: download, Esc: none)$summary" |
                    cut -f1,2)
            fi
            # nothing to download: the check's results stay on screen
            if (( n == 0 )); then
                while IFS= read -r line; do
                    [[ -n "$line" ]] || continue
                    paint line "$line"
                    printf '%s\n' "$line"
                done <<<"${summary#$'\n'}"
                if (( ${#lines[@]} )); then line="nothing downloaded"; else line="✓ nothing to update"; fi
                paint line "$line"
                printf '%s\n' "$line"
            fi
        fi
    fi

    # the downloads: the updates kept above, and the single items from step 2,
    # in the usual order
    if (( ${#runs[@]} )); then
        local -a order=()
        for m in app apw iso; do [[ " ${runs[*]} " == *" $m "* ]] && order+=("$m"); done
        HEADING_NOTE=""
        [[ "$check_only" == true ]] || HEADING_NOTE="updating"
        run_modes "${order[@]}" || rc=1
    fi
    return "$rc"
}
