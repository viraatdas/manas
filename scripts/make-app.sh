#!/usr/bin/env bash
# Builds Manas.app from the SPM package: release binary, icon, Info.plist,
# ad-hoc signature. Output lands at dist/Manas.app (repo-relative).
#
#   scripts/make-app.sh
#
# Install/update the real app afterwards with:
#   rm -rf /Applications/Manas.app && cp -R dist/Manas.app /Applications/
#
# Ad-hoc signing (codesign -s -) is enough for a locally built app to run on
# this machine; notarization is deliberately out of scope (no public release).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Manas"
BUNDLE_ID="dev.viraat.manas"
DIST_DIR="$REPO_ROOT/dist"
APP="$DIST_DIR/$APP_NAME.app"
ICON_SRC="$REPO_ROOT/assets/icon/Manas.icns"

echo "==> Building $APP_NAME (release)"
swift build -c release --package-path "$REPO_ROOT" --product "$APP_NAME"
BIN_PATH="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)/$APP_NAME"
[[ -x "$BIN_PATH" ]] || { echo "error: built binary not found at $BIN_PATH" >&2; exit 1; }
[[ -f "$ICON_SRC" ]] || { echo "error: icon not found at $ICON_SRC" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON_SRC" "$APP/Contents/Resources/$APP_NAME.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP"
