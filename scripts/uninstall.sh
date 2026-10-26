#!/bin/zsh
# Stops the bridge (it hands the mic back to macOS on exit) and removes the service.
# Usage: scripts/uninstall.sh [--purge]   (--purge also deletes the install folder and log)
set -euo pipefail
LABEL="local.fifine-a8.bridge"
INSTALL_DIR="$HOME/Library/Application Support/fifine-a8-bridge"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL" && echo "service stopped - the fifine is handed back to macOS"
fi
rm -f "$AGENT" && echo "removed $AGENT"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$INSTALL_DIR" && echo "removed $INSTALL_DIR"
fi
sleep 2
if system_profiler SPAudioDataType 2>/dev/null | grep -q "fifine Microphone:"; then
  echo "the fifine is visible to macOS again"
else
  echo "the fifine is not visible yet - if it stays missing, unplug and replug it"
fi
