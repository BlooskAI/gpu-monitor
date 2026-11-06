#!/bin/zsh
set -euo pipefail
LABEL="com.utils.gpumonitor"
launchctl kickstart -k "gui/$UID/$LABEL"
sleep 2
zsh "$(cd "$(dirname "$0")" && pwd)/status.sh"
