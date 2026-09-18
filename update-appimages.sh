#!/usr/bin/env bash
# ~/AppImages/update-appimages.sh
set -uo pipefail

APPIMAGES_DIR="$HOME/AppImages"

for app_dir in "$APPIMAGES_DIR"/*/; do
    [[ -d "$app_dir" ]] || continue
    app_name=$(basename "$app_dir")

    appimage_file=$(find "$app_dir" -maxdepth 1 -iname "*.appimage" -type f | head -n 1)
    json_file=$(find "$app_dir" -maxdepth 1 -iname "*.appimage.json" -type f | head -n 1)

    if [[ -z "$appimage_file" ]]; then
        echo "⚠ $app_name: no AppImage found, skipping"
        continue
    fi

    if [[ -z "$json_file" ]]; then
        echo "⚠ $app_name: no update metadata found, skipping"
        continue
    fi

    manager=$(jq -r '.manager' "$json_file")
    current_version=$(jq -r '.current_version // empty' "$json_file")

    case "$manager" in
        github)
            repo=$(jq -r '.repo' "$json_file")
            pattern=$(jq -r '.repo_filename' "$json_file")
            allow_pre=$(jq -r '.allow_prereleases // false' "$json_file")

            api_url="https://api.github.com/repos/$repo/releases"
            [[ "$allow_pre" == "false" ]] && api_url="$api_url/latest"

            release_json=$(curl -s "$api_url")
            latest_tag=$(echo "$release_json" | jq -r 'if type=="array" then .[0].tag_name else .tag_name end')
            asset_url=$(echo "$release_json" | jq -r --arg pat "$pattern" '
                (if type=="array" then .[0] else . end).assets[]
                | select(.name | test($pat | gsub("\\*"; ".*")))
                | .browser_download_url' | head -n 1)
            ;;
        gitlab)
            repo_url=$(jq -r '.repo_url' "$json_file")
            pattern=$(jq -r '.repo_filename' "$json_file")
            project_path=$(echo "$repo_url" | sed -E 's#https://gitlab.com/##')
            encoded_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$project_path")

            release_json=$(curl -s "https://gitlab.com/api/v4/projects/$encoded_path/releases")
            latest_tag=$(echo "$release_json" | jq -r '.[0].tag_name')
            asset_url=$(echo "$release_json" | jq -r --arg pat "$pattern" '
                .[0].assets.links[]
                | select(.name | test($pat | gsub("\\*"; ".*")))
                | .direct_asset_url' | head -n 1)
            ;;
        static)
            url=$(jq -r '.url' "$json_file")
            latest_tag="static"
            asset_url="$url"
            ;;
        *)
            echo "⚠ $app_name: unknown manager '$manager', skipping"
            continue
            ;;
    esac

    if [[ "$manager" != "static" && "$latest_tag" == "$current_version" ]]; then
        echo "✓ $app_name is up to date ($current_version)"
        continue
    fi

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        echo "⚠ $app_name: could not resolve download URL, skipping"
        continue
    fi

    echo "⬆ Updating $app_name..."
    tmp_file="${appimage_file}.new"
    if curl -sL "$asset_url" -o "$tmp_file"; then
        mv "$appimage_file" "${appimage_file}.bak"
        mv "$tmp_file" "$appimage_file"
        chmod +x "$appimage_file"

        # Update stored version
        tmp_json=$(mktemp)
        jq --arg v "$latest_tag" '.current_version = $v' "$json_file" > "$tmp_json" && mv "$tmp_json" "$json_file"

        echo "  ✓ $app_name updated to $latest_tag"
    else
        echo "  ✗ Failed to download update for $app_name"
        rm -f "$tmp_file"
    fi
done
