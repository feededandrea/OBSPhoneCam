#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
zip -r ../OBSPhoneCam.zip . -x "*.DS_Store" "*.xcodeproj/*" ".build/*"
