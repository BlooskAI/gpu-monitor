#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-2.2.0}"
APP="$(zsh "$ROOT/scripts/build-app.sh")"
ARCHIVE="$ROOT/dist/BlooskAI-GpuMonitor-macOS-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
echo "$ARCHIVE"
