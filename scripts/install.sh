#!/bin/zsh
# Builds and installs the fifine A8 bridge as a per-user background service (LaunchAgent).
# No admin rights needed. Usage: scripts/install.sh
set -euo pipefail
ROOT=${0:A:h:h}
LABEL="local.fifine-a8.bridge"
INSTALL_DIR="$HOME/Library/Application Support/fifine-a8-bridge"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_=$(id -u)

say() { print -P "%F{cyan}==>%f $*"; }
warn() { print -P "%F{yellow}warning:%f $*"; }

# 1) Prerequisites
[[ $(uname) == Darwin ]] || { echo "macOS only"; exit 1; }
if ! system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole 2ch"; then
  echo "BlackHole 2ch is not installed. Install it first:"
  echo "    brew install --cask blackhole-2ch      (or download from https://existential.audio/blackhole/)"
  exit 1
fi
if ! ioreg -p IOUSB -l -w0 2>/dev/null | grep -q '"idVendor" = 12610'; then
  warn "no fifine A8 (USB 3142:0c08) is connected right now - installing anyway; the bridge waits for it."
fi

# 2) Build
"$ROOT/scripts/build.sh"

# 3) Stop older installs so two bridges never fight over the mic
for old in "$LABEL" com.user.fifine-bridge com.user.fifine-autoheal; do
  if launchctl print "gui/$UID_/$old" >/dev/null 2>&1; then
    say "stopping existing service $old"
    launchctl bootout "gui/$UID_/$old" || true
  fi
done
for oldplist in "$HOME/Library/LaunchAgents/com.user.fifine-bridge.plist" "$HOME/Library/LaunchAgents/com.user.fifine-autoheal.plist"; do
  if [[ -f "$oldplist" ]]; then
    mkdir -p "$INSTALL_DIR/replaced-services"
    mv "$oldplist" "$INSTALL_DIR/replaced-services/"
    say "moved older service definition $(basename "$oldplist") to $INSTALL_DIR/replaced-services/"
  fi
done

# 4) Install the app and the service
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/fifine-bridge.app"
cp -R "$ROOT/build/fifine-bridge.app" "$INSTALL_DIR/"
cp "$ROOT/build/tools/usbreset" "$INSTALL_DIR/"
sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$ROOT/launchd/$LABEL.plist.template" > "$AGENT"
plutil -lint "$AGENT" >/dev/null
launchctl bootstrap "gui/$UID_" "$AGENT"
say "service started"

cat <<EOF

Next steps
  1. macOS will ask whether "fifine bridge" may use the microphone -> click Allow.
     (If no pop-up appears: System Settings > Privacy & Security > Microphone > enable "fifine bridge".)
  2. In Zoom / Teams / Meet / Discord, choose "BlackHole 2ch" as the microphone.
     The fifine itself disappears from macOS's device list while the bridge runs - that is expected.
  3. Recommended: turn off "Automatically adjust microphone volume" in Zoom (Settings > Audio).

Log:          $INSTALL_DIR/bridge.log
Diagnostics:  touch "$INSTALL_DIR/diagnostics-on"   (stats every 10 s; delete the file to stop)
Uninstall:    $ROOT/scripts/uninstall.sh
EOF
sleep 3
echo; echo "--- latest log lines:"; tail -n 5 "$INSTALL_DIR/bridge.log" 2>/dev/null || true
