#!/bin/zsh
set -euo pipefail
LABEL="com.utils.gpumonitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_APP="${INSTALL_DIR:-$HOME/Applications}/GPU Monitor.app"
launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$INSTALL_APP"
echo "GPU Monitor removed. Repository source and logs were retained."

