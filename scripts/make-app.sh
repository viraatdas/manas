#!/usr/bin/env bash
# Builds Manas.app from the SPM package: release binary, icon, Info.plist,
# and signature. Output lands at dist/Manas.app (repo-relative).
#
#   scripts/make-app.sh
#
# Install/update the real app afterwards with:
#   ditto dist/Manas.app /Applications/Manas.app
#
# A Developer ID identity is preferred when one is available so Full Disk
# Access remains attached to a stable code requirement across local rebuilds.
# Set MANAS_CODESIGN_IDENTITY to override it; otherwise the script falls back
# to ad-hoc signing. Notarization is deliberately out of scope here.

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
	<string>0.1.3</string>
	<key>CFBundleVersion</key>
	<string>4</string>
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

SIGN_IDENTITY="${MANAS_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Developer ID Application/ { print $2; exit }')"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> Signing (ad-hoc fallback)"
  codesign --force --deep -s - "$APP"
else
  echo "==> Signing ($SIGN_IDENTITY)"
  codesign --force --deep --timestamp=none -s "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Done: $APP"
