#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT="${OUTPUT:-$ROOT/dist}"
APP="$OUTPUT/GPU Monitor.app"

command -v swift >/dev/null || { echo "Swift is required. Install current Xcode Command Line Tools." >&2; exit 1; }
mkdir -p "$OUTPUT"
cd "$ROOT"
swift build -c "$CONFIGURATION" >&2
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GpuMonitor" "$APP/Contents/MacOS/GpuMonitor"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/blooskai-mark.png" "$APP/Contents/Resources/blooskai-mark.png"
LICENSE_ROOT="$ROOT"
[[ -f "$LICENSE_ROOT/LICENSE" ]] || LICENSE_ROOT="$ROOT/.."
cp "$LICENSE_ROOT/LICENSE" "$LICENSE_ROOT/NOTICE" "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/MacOS/GpuMonitor"
codesign --force --deep --sign - "$APP"
echo "$APP"

