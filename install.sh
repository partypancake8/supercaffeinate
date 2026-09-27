#!/bin/bash
# Install supercaffeinate for the current user. Safe to re-run.
#   1. Copies bin/supercaffeinate and bin/supercaffeinate-setup to ~/bin
#   2. Compiles screenblank/main.swift to ~/bin/screenblank
#   3. Builds the menu bar app into ~/Applications/SuperCaffeinate.app
#   4. Renders the LaunchAgent with your $HOME and loads it
# Afterwards run `supercaffeinate-setup` once for the pmset sudoers rule.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/bin"
LABEL=com.sawyer.supercaffeinate-menubar
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "== supercaffeinate install =="

# 1. scripts
mkdir -p "$BIN_DIR"
install -m 755 "$REPO/bin/supercaffeinate" "$BIN_DIR/supercaffeinate"
install -m 755 "$REPO/bin/supercaffeinate-setup" "$BIN_DIR/supercaffeinate-setup"
echo "[1/4] Copied supercaffeinate and supercaffeinate-setup to $BIN_DIR"

# 2. screenblank helper, compiled from source
mkdir -p "$REPO/build"
/usr/bin/swiftc -O -framework CoreGraphics -o "$REPO/build/screenblank" "$REPO/screenblank/main.swift"
# Kill a running copy first so the screen is not left blacked out by an old binary.
pkill -x screenblank 2>/dev/null || true
install -m 755 "$REPO/build/screenblank" "$BIN_DIR/screenblank"
echo "[2/4] Built and installed $BIN_DIR/screenblank"

# 3. LaunchAgent (rendered before the app build so build.sh reloads it)
mkdir -p "$HOME/Library/LaunchAgents"
TMP=$(mktemp)
sed "s|__HOME__|$HOME|g" "$REPO/launchagent/$LABEL.plist.template" > "$TMP"
if [ -f "$PLIST" ] && cmp -s "$TMP" "$PLIST"; then
  rm -f "$TMP"
  echo "[3/4] LaunchAgent already up to date at $PLIST"
else
  mv "$TMP" "$PLIST"
  chmod 644 "$PLIST"
  echo "[3/4] Wrote $PLIST"
fi

# 4. menu bar app (build.sh installs it and boots out / bootstraps the agent)
echo "[4/4] Building the menu bar app"
"$REPO/menubar/build.sh"

echo
echo "Done. Make sure $BIN_DIR is on your PATH, then run once:"
echo "  supercaffeinate-setup"
