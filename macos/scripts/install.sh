#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GPU Monitor.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP="$INSTALL_DIR/$APP_NAME"
LABEL="com.utils.gpumonitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/UtilsGpuMonitor"

[[ "$(uname -s)" == "Darwin" ]] || { echo "This installer is for macOS." >&2; exit 1; }
APP_PATH="$(zsh "$ROOT/scripts/build-app.sh")"
mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents" "$LOG_DIR"
rm -rf "$INSTALL_APP"
ditto "$APP_PATH" "$INSTALL_APP"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$INSTALL_APP/Contents/MacOS/GpuMonitor</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG_DIR/stdout.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/stderr.log</string>
</dict></plist>
PLIST

launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"
echo "Installed $INSTALL_APP"
zsh "$ROOT/scripts/status.sh"
