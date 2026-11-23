#!/bin/sh
set -eu

LABEL="com.zandenkane.dockmute"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DEST="$HOME/Applications/DockMute.app"
USER_UID="$(id -u)"

launchctl bootout "gui/$USER_UID/$LABEL" >/dev/null 2>&1 || true
launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
pkill -x DockMute >/dev/null 2>&1 || true

rm -f "$PLIST_PATH"
rm -rf "$APP_DEST"

# Restore standard Dock visibility and default hover delay
defaults write com.apple.dock autohide -bool false
defaults delete com.apple.dock autohide-delay >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true

echo "Removed DockMute and restored standard Dock settings."
