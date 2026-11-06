#!/bin/zsh
set -u
LABEL="com.utils.gpumonitor"
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  echo "LaunchAgent: loaded"
  launchctl print "gui/$UID/$LABEL" | grep -E 'state =|pid =|last exit code =' || true
else
  echo "LaunchAgent: not loaded"
  exit 1
fi

