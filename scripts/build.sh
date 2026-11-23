#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/DockMute.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
SDK_PATH="$(xcrun --show-sdk-path)"
MIN_MACOS="11.0"

SOURCES="
$ROOT_DIR/Sources/DockController.swift
$ROOT_DIR/Sources/AudioMuteController.swift
$ROOT_DIR/Sources/SystemEventMonitor.swift
$ROOT_DIR/Sources/StatusBarController.swift
$ROOT_DIR/Sources/main.swift
"

FRAMEWORKS="-framework AppKit -framework CoreAudio -framework AudioToolbox -framework CoreGraphics -framework IOKit"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

compile_slice() {
    ARCH="$1"
    MIN_VER="$2"
    OUT="$3"
    echo "Compiling DockMute ($ARCH, macOS $MIN_VER+)..."
    # shellcheck disable=SC2086
    swiftc -O -sdk "$SDK_PATH" -target "$ARCH-apple-macosx$MIN_VER" $FRAMEWORKS $SOURCES -o "$OUT"
}

if command -v lipo >/dev/null 2>&1; then
    ARM_BIN="$BUILD_DIR/DockMute-arm64"
    X64_BIN="$BUILD_DIR/DockMute-x86_64"
    ARM_OK=0
    X64_OK=0

    if compile_slice arm64 "$MIN_MACOS" "$ARM_BIN"; then
        ARM_OK=1
    fi

    # Newer Apple Silicon SDKs omit x86_64 Swift 5.6 back-deployment stubs; retry macOS 13.0 for x86_64 if needed.
    if compile_slice x86_64 "$MIN_MACOS" "$X64_BIN" 2>/dev/null; then
        X64_OK=1
    elif compile_slice x86_64 "13.0" "$X64_BIN"; then
        X64_OK=1
    fi

    if [ "$ARM_OK" = "1" ] && [ "$X64_OK" = "1" ]; then
        lipo -create "$ARM_BIN" "$X64_BIN" -output "$MACOS_DIR/DockMute"
        rm -f "$ARM_BIN" "$X64_BIN"
    elif [ "$ARM_OK" = "1" ]; then
        mv "$ARM_BIN" "$MACOS_DIR/DockMute"
        rm -f "$X64_BIN"
    elif [ "$X64_OK" = "1" ]; then
        mv "$X64_BIN" "$MACOS_DIR/DockMute"
        rm -f "$ARM_BIN"
    else
        echo "Failed to compile DockMute for any architecture." >&2
        exit 1
    fi
else
    HOST_ARCH="$(uname -m)"
    compile_slice "$HOST_ARCH" "$MIN_MACOS" "$MACOS_DIR/DockMute"
fi

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
xattr -cr "$APP_DIR" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
if command -v lipo >/dev/null 2>&1; then
    lipo -info "$MACOS_DIR/DockMute"
fi
