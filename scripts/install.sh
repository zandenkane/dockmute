#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DEST="$HOME/Applications/DockMute.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LABEL="com.zandenkane.dockmute"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
USER_UID="$(id -u)"

"$SCRIPT_DIR/build.sh"

# Stop any currently running instance
launchctl bootout "gui/$USER_UID/$LABEL" >/dev/null 2>&1 || true
launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
pkill -x DockMute >/dev/null 2>&1 || true

mkdir -p "$HOME/Applications" "$LAUNCH_AGENTS_DIR"
rm -rf "$APP_DEST"
cp -R "$ROOT_DIR/build/DockMute.app" "$APP_DEST"
xattr -cr "$APP_DEST" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP_DEST"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DEST/Contents/MacOS/DockMute</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

if ! launchctl bootstrap "gui/$USER_UID" "$PLIST_PATH" >/dev/null 2>&1; then
    launchctl load -w "$PLIST_PATH"
fi

echo "Installed and started DockMute at $APP_DEST"
echo "Login LaunchAgent registered at $PLIST_PATH"
