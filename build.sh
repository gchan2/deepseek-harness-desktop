#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="DeepSeekHarness"
DISPLAY_NAME="DeepSeek Harness"
BUNDLE_ID="com.deepseek.harness"
VERSION="0.1.0"
BUILD="1"
APP_DIR="$ROOT/$APP_NAME.app"
STAGE="$ROOT/build/stage"
DIST="$ROOT/dist"
RES_SRC="$ROOT/dsh"
ICON_MASTER="$ROOT/build/icon_1024.png"

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$DIST" "$ROOT/build"

# 0. Bootstrap: install the dsh runtime if missing
if [[ ! -d "$RES_SRC/node_modules" ]]; then
  echo "==> Installing @deepseek-ai/dsh (first run)"
  ( cd "$RES_SRC" && npm install )
fi

# 1. Compile the Swift launcher
echo "==> Compiling Swift launcher"
swiftc -O -framework AppKit -framework WebKit src/main.swift -o "$STAGE/Contents/MacOS/$APP_NAME"

# 2. Render the app icon + menu bar icon, then build the .icns
echo "==> Rendering icons"
mkdir -p "$ROOT/build"
swiftc -O src/makeicon.swift -o "$ROOT/build/makeicon"
( cd "$ROOT" && "$ROOT/build/makeicon" "$ICON_MASTER" )

echo "==> Building icon.icns"
ICONSET="$STAGE/build.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
sips -z 16 16     "$ICON_MASTER" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32 32     "$ICON_MASTER" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64 64     "$ICON_MASTER" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
sips -z 128 128   "$ICON_MASTER" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256 256   "$ICON_MASTER" --out "$ICONSET/icon_128x128@2x.png">/dev/null
sips -z 256 256   "$ICON_MASTER" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512 512   "$ICON_MASTER" --out "$ICONSET/icon_256x256@2x.png">/dev/null
sips -z 512 512   "$ICON_MASTER" --out "$ICONSET/icon_512x512.png"   >/dev/null
cp "$ICON_MASTER" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/icon.icns"
rm -rf "$ICONSET"
cp "$ROOT/menubar.png" "$STAGE/Contents/Resources/menubar.png"
cp "$ROOT/menubar@2x.png" "$STAGE/Contents/Resources/menubar@2x.png"

# 3. Bundle dsh runtime into Resources
echo "==> Bundling dsh node_modules"
rm -rf "$STAGE/Contents/Resources/dsh"
mkdir -p "$STAGE/Contents/Resources/dsh"
cp -R "$RES_SRC/node_modules" "$STAGE/Contents/Resources/dsh/node_modules"
cp "$RES_SRC/bin-wrapper.mjs" "$STAGE/Contents/Resources/dsh/bin-wrapper.mjs"
cp "$RES_SRC/package.json" "$STAGE/Contents/Resources/dsh/package.json" 2>/dev/null || true

# 4. Info.plist
echo "==> Writing Info.plist"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key>
  <string>$BUILD</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>icon</string>
  <key>CFBundleIconName</key>
  <string>icon</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSAllowsArbitraryLoadsInWebContent</key>
    <true/>
  </dict>
  <key>CFBundleDocumentTypes</key>
  <array/>
  <key>NSHumanReadableCopyright</key>
  <string>DeepSeek Harness — MIT License (DeepSeek AI)</string>
</dict>
</plist>
PLIST

# 5. PkgInfo (helps LaunchServices identify the app)
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# 6. Move stage to final app
rm -rf "$APP_DIR"
mv "$STAGE" "$APP_DIR"

# 7. Ad-hoc codesign
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
  codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

# 8. Stage a copy in dist
rm -rf "$DIST/$APP_NAME.app"
cp -R "$APP_DIR" "$DIST/$APP_NAME.app"

echo "==> Built $APP_DIR"
echo "    (copy in $DIST/$APP_NAME.app)"

# 9. Install to /Applications if requested
if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  if cp -R "$APP_DIR" "/Applications/$APP_NAME.app" 2>/dev/null; then
    xattr -c "/Applications/$APP_NAME.app" 2>/dev/null || true
    echo "    Installed to /Applications/$APP_NAME.app"
  else
    echo "    /Applications is not writable. Try: sudo cp -R \"$APP_DIR\" \"/Applications/$APP_NAME.app\""
  fi
fi
