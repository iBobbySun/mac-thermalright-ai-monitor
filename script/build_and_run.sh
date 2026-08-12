#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MacTR"
BUNDLE_ID="com.beret21.MacTR"
MIN_SYSTEM_VERSION="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_INFO_PLIST="$ROOT_DIR/Sources/MacTR/Resources/Info.plist"
APP_ICON="$ROOT_DIR/Sources/MacTR/Resources/AppIcon.icns"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_INFO_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_INFO_PLIST")"

swift build -c release
BUILD_BIN_DIR="$(swift build -c release --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp -R "$BUILD_BIN_DIR/Sparkle.framework" "$APP_FRAMEWORKS/"
cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_BINARY"

VENDORED_LIBUSB="$ROOT_DIR/.build/vendor/libusb-macos15/lib/libusb-1.0.0.dylib"
LINKED_LIBUSB="$(otool -L "$APP_BINARY" | awk '/libusb-1\.0\.0\.dylib/{print $1; exit}')"
if [[ -f "$VENDORED_LIBUSB" ]]; then
  LIBUSB_DYLIB="$VENDORED_LIBUSB"
else
  LIBUSB_DYLIB="$LINKED_LIBUSB"
fi
if [[ -z "$LINKED_LIBUSB" || -z "$LIBUSB_DYLIB" || ! -f "$LIBUSB_DYLIB" ]]; then
  echo "unable to locate the linked libusb dylib" >&2
  exit 1
fi
cp -L "$LIBUSB_DYLIB" "$APP_FRAMEWORKS/"
LIBUSB_BASENAME="$(basename "$LIBUSB_DYLIB")"
chmod u+w "$APP_FRAMEWORKS/$LIBUSB_BASENAME"
install_name_tool -change "$LINKED_LIBUSB" "@rpath/$LIBUSB_BASENAME" "$APP_BINARY"
install_name_tool -id "@rpath/$LIBUSB_BASENAME" "$APP_FRAMEWORKS/$LIBUSB_BASENAME"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -n "$APP_BUNDLE"
}

sign_app() {
  xattr -cr "$APP_BUNDLE"
  codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

case "$MODE" in
  build)
    sign_app
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [build|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
