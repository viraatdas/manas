#!/usr/bin/env bash
# Builds Manas.app from the SPM package: release binary, icon, Info.plist,
# embedded Sparkle updater, and signature. Output lands at dist/Manas.app
# (repo-relative).
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
#
# Shipping a new version is three steps: bump VERSION/BUILD below, run this
# script, then scripts/release.sh to notarize, publish, and refresh the
# appcast that installed copies poll.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Manas"
BUNDLE_ID="dev.viraat.manas"
VERSION="1.0.1"
BUILD="36"
# Where installed copies look for new versions, and the public half of the
# EdDSA key their Sparkle verifies the feed with. The private half lives in the
# login keychain (Sparkle's generate_keys); scripts/release.sh signs with it.
APPCAST_URL="https://manas.viraat.dev/appcast.xml"
SPARKLE_PUBLIC_KEY="P5QH0XAKouuSIU8RJtzTTH/6dfUDP/BBc3OtoKP8Yfg="
DIST_DIR="$REPO_ROOT/dist"
APP="$DIST_DIR/$APP_NAME.app"
ICON_SRC="$REPO_ROOT/assets/icon/Manas.icns"
# release.env (gitignored) carries the analytics token for both platforms, so
# a release build picks it up without anyone having to remember to export it.
# An explicit env var still wins, for one-off builds.
if [[ -z "${MANAS_POSTHOG_PROJECT_TOKEN:-}" && -f "$REPO_ROOT/release.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/release.env"
fi
POSTHOG_TOKEN="${MANAS_POSTHOG_PROJECT_TOKEN:-}"
if [[ "$POSTHOG_TOKEN" == phc_* ]]; then
  echo "==> Analytics enabled (${POSTHOG_TOKEN:0:12}…)"
else
  echo "==> No analytics token — building without analytics"
fi
ANALYTICS_PLIST_ENTRY=""
if [[ "$POSTHOG_TOKEN" == phc_* ]]; then
  ANALYTICS_PLIST_ENTRY=$'\t<key>ManasPostHogProjectToken</key>\n\t<string>'"$POSTHOG_TOKEN"$'</string>'
fi

echo "==> Building $APP_NAME (release)"
swift build -c release --package-path "$REPO_ROOT" --product "$APP_NAME"
BIN_PATH="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)/$APP_NAME"
[[ -x "$BIN_PATH" ]] || { echo "error: built binary not found at $BIN_PATH" >&2; exit 1; }
[[ -f "$ICON_SRC" ]] || { echo "error: icon not found at $ICON_SRC" >&2; exit 1; }

SPARKLE_SRC="$(find "$REPO_ROOT/.build/artifacts" -type d -name 'Sparkle.framework' -path '*macos*' -print -quit)"
[[ -d "$SPARKLE_SRC" ]] || { echo "error: Sparkle.framework not found under .build/artifacts" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON_SRC" "$APP/Contents/Resources/$APP_NAME.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ditto rather than cp -R: the framework is a tree of symlinks whose layout
# codesign refuses to accept if it is flattened.
ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"

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
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>SUFeedURL</key>
	<string>$APPCAST_URL</string>
	<key>SUPublicEDKey</key>
	<string>$SPARKLE_PUBLIC_KEY</string>
	<!-- Check daily, then download and install without asking. Sparkle only
	     accepts a build carrying the same Developer ID signature as this one,
	     so the swap keeps the app's Full Disk Access grant. -->
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUAutomaticallyUpdate</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
$ANALYTICS_PLIST_ENTRY
	<!-- Reading names for the people in a shared group. The out-of-process
	     contact picker needs no permission, but naming a member the user never
	     picked does: it reads CNContactStore. Names are matched and drawn on
	     this Mac and never leave it. -->
	<key>NSContactsUsageDescription</key>
	<string>Manas shows the people in a shared list by name instead of by phone number. Names stay on this Mac and are never uploaded.</string>
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

# The hardened runtime (`--options runtime`, below) does not merely want a
# usage string for Contacts — it requires the entitlement as well, and without
# it the request is refused before it ever reaches TCC. No prompt, no denial
# recorded, no row in the TCC database at all: the app just reads an empty
# address book forever while `NSContactsUsageDescription` sits in the plist
# looking like the whole story. That is exactly how member names shipped inert
# in 0.4.6 through 0.4.8.
#
# Deliberately NOT the App Sandbox. This app reads Messages, Arc history and
# knowledgeC through Full Disk Access, and sandboxing it would cut all three
# off. `personal-information.addressbook` is a hardened-runtime resource
# entitlement and stands on its own.
ENTITLEMENTS="$DIST_DIR/Manas.entitlements"
cat > "$ENTITLEMENTS" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.personal-information.addressbook</key>
	<true/>
</dict>
</plist>
ENTS

SIGN_IDENTITY="${MANAS_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Developer ID Application/ { print $2; exit }')"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Sparkle ships its own nested helpers (two XPC services, an updater app, and
# the Autoupdate tool). Each is a separate code-signing target and has to be
# signed before the framework that contains it — `--deep` walks the tree in an
# order codesign itself calls unreliable, and leaves the helpers unusable.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
NESTED=(
  "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
  "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
  "$SPARKLE_FW/Versions/B/Updater.app"
  "$SPARKLE_FW/Versions/B/Autoupdate"
  "$SPARKLE_FW"
)

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> Signing (ad-hoc fallback)"
  for target in "${NESTED[@]}"; do
    [[ -e "$target" ]] && codesign --force -s - "$target"
  done
  # Entitlements on the scratch build too, or a local verification run cannot
  # exercise the real Contacts path at all.
  codesign --force -s - --entitlements "$ENTITLEMENTS" "$APP"
else
  echo "==> Signing ($SIGN_IDENTITY)"
  for target in "${NESTED[@]}"; do
    [[ -e "$target" ]] && \
      codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$target"
  done
  # Only the app itself carries them; the Sparkle helpers have no business
  # reading an address book.
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --deep "$APP"

# A silent regression here is invisible until somebody notices names never
# resolve, so fail the build rather than ship another inert release.
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | grep -q "com.apple.security.personal-information.addressbook" \
  || { echo "error: $APP is missing the Contacts entitlement" >&2; exit 1; }

echo "==> Done: $APP"
