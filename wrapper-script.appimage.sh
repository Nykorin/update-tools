#!/usr/bin/env bash
DIR="$(dirname "$(readlink -f "$0")")"

APPIMAGE=$(find "$DIR" -maxdepth 1 -iname "*.appimage" -type f | head -n 1)

export HOME="$DIR/$(basename "$APPIMAGE").home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

exec "$APPIMAGE" "$@"
