#!/usr/bin/env bash
# ~/AppImages/update-appimages.sh
# Scans ~/AppImages/*/ for AppImages and updates them using AppImageUpdate.

set -uo pipefail

APPIMAGES_DIR="$HOME/AppImages"

if ! command -v AppImageUpdate &>/dev/null && [[ ! -x "$APPIMAGES_DIR/AppImageUpdate.AppImage" ]]; then
    echo "ERROR: AppImageUpdate not found. Install it or place it at $APPIMAGES_DIR/AppImageUpdate.AppImage" >&2
    exit 1
fi

UPDATER="AppImageUpdate"
command -v AppImageUpdate &>/dev/null || UPDATER="$APPIMAGES_DIR/AppImageUpdate.AppImage"

for app_dir in "$APPIMAGES_DIR"/*/; do
    [[ -d "$app_dir" ]] || continue
    app_name=$(basename "$app_dir")

    # Find the .appimage file inside this app's folder (case-insensitive)
    appimage_file=$(find "$app_dir" -maxdepth 1 -iname "*.appimage" -type f | head -n 1)

    if [[ -z "$appimage_file" ]]; then
        echo "  ⚠ $app_name: no AppImage found, skipping"
        continue
    fi

    echo "Checking $app_name..."

    # -j checks if an update is available without applying it
    if "$UPDATER" --check-for-update "$appimage_file" &>/dev/null; then
        echo "  ✓ $app_name is up to date"
    else
        echo "  ⬆ Updating $app_name..."
        "$UPDATER" "$appimage_file"
    fi
done
