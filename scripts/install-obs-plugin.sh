#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_NAME="obs-phone-cam"
SOURCE_PLUGIN="$ROOT_DIR/OBSPlugin/build/$PLUGIN_NAME.plugin"
DEST_DIR="$HOME/Library/Application Support/obs-studio/plugins"
DEST_PLUGIN="$DEST_DIR/$PLUGIN_NAME.plugin"

if [[ ! -d "$SOURCE_PLUGIN" ]]; then
  "$ROOT_DIR/scripts/build-obs-plugin.sh" >/dev/null
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST_PLUGIN"
cp -R "$SOURCE_PLUGIN" "$DEST_PLUGIN"
codesign --verify --deep --strict --verbose=1 "$DEST_PLUGIN"

echo "$DEST_PLUGIN"
