#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS_APP="${OBS_APP:-/Applications/OBS.app}"
OBS_VERSION="${OBS_VERSION:-31.0.3}"
OBS_HEADERS_DIR="$ROOT_DIR/.build/obs-headers"
PLUGIN_NAME="obs-phone-cam"
PLUGIN_DIR="$ROOT_DIR/OBSPlugin/build/$PLUGIN_NAME.plugin"
PLUGIN_BIN="$PLUGIN_DIR/Contents/MacOS/$PLUGIN_NAME"
INFO_PLIST="$PLUGIN_DIR/Contents/Info.plist"

if [[ ! -d "$OBS_APP" ]]; then
  echo "OBS.app not found at $OBS_APP"
  exit 1
fi

if [[ ! -f "$OBS_HEADERS_DIR/libobs/obs-module.h" ]]; then
  mkdir -p "$ROOT_DIR/.build"
  curl -L --fail --silent --show-error \
    "https://github.com/obsproject/obs-studio/archive/refs/tags/$OBS_VERSION.tar.gz" \
    -o "$ROOT_DIR/.build/obs-studio-$OBS_VERSION.tar.gz"
  rm -rf "$OBS_HEADERS_DIR"
  mkdir -p "$OBS_HEADERS_DIR"
  tar -xzf "$ROOT_DIR/.build/obs-studio-$OBS_VERSION.tar.gz" -C "$OBS_HEADERS_DIR" --strip-components=1
fi

rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR/Contents/MacOS" "$PLUGIN_DIR/Contents/Resources"

clang -std=c17 -fmodules -fobjc-arc -fPIC -bundle \
  -fmodules-cache-path="$ROOT_DIR/.build/clang-module-cache" \
  -I"$OBS_HEADERS_DIR/libobs" \
  -I"$OBS_HEADERS_DIR/libobs/util" \
  -I"$OBS_HEADERS_DIR/libobs/graphics" \
  -I"$OBS_HEADERS_DIR/libobs/media-io" \
  -F"$OBS_APP/Contents/Frameworks" \
  -framework libobs \
  -Wl,-rpath,"$OBS_APP/Contents/Frameworks" \
  "$ROOT_DIR/OBSPlugin/src/obs-phone-cam.c" \
  -o "$PLUGIN_BIN"

cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PLUGIN_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.dinesys.obsphonecam.obs-plugin</string>
  <key>CFBundleName</key>
  <string>OBS Phone Cam</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$PLUGIN_DIR" >/dev/null

echo "$PLUGIN_DIR"
