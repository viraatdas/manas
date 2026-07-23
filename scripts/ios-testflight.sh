#!/usr/bin/env bash
# Builds and uploads the iOS app to TestFlight, end to end:
#
#   scripts/ios-testflight.sh            # archive + export + upload
#   scripts/ios-testflight.sh archive    # stop after the signed .ipa
#
# Signing is MANUAL with an API-key-fetched Distribution cert and App Store
# profiles for the app + widget (fastlane prep_signing) — Xcode cloud signing
# rejects this team key, and slide shipped the same way. The app record itself
# must already exist on App Store Connect (`fastlane bootstrap` covers bundle
# ids; the record needs a web session once).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
BUILD_DIR="$IOS_DIR/build"
ARCHIVE="$BUILD_DIR/Manas.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

# shellcheck disable=SC1091
source "$IOS_DIR/fastlane/.asc.env"
: "${ASC_KEY_ID:?fill ios/fastlane/.asc.env}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}" "${APPLE_TEAM_ID:?}"

echo "==> Generating Xcode project"
(cd "$IOS_DIR" && xcodegen generate)

echo "==> Fetching Distribution cert + App Store profiles"
(cd "$IOS_DIR" && fastlane prep_signing)

echo "==> Archiving (Release, manual signing)"
xcodebuild archive \
  -project "$IOS_DIR/Manas.xcodeproj" \
  -scheme Manas \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  | grep -E "error|warning: Signing|ARCHIVE" || true
[[ -d "$ARCHIVE" ]] || { echo "error: archive missing at $ARCHIVE" >&2; exit 1; }

echo "==> Exporting .ipa (app-store-connect)"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>export</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>teamID</key>
	<string>$APPLE_TEAM_ID</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>dev.viraat.manas.ios</key>
		<string>dev.viraat.manas.ios AppStore</string>
		<key>dev.viraat.manas.ios.widget</key>
		<string>dev.viraat.manas.ios.widget AppStore</string>
	</dict>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  | grep -E "error|EXPORT" || true
IPA="$EXPORT_DIR/Manas.ipa"
[[ -f "$IPA" ]] || { echo "error: ipa missing at $IPA" >&2; exit 1; }
cp "$IPA" "$BUILD_DIR/Manas.ipa"
echo "==> Exported $BUILD_DIR/Manas.ipa"

if [[ "${1:-}" == "archive" ]]; then
  exit 0
fi

echo "==> Uploading to TestFlight"
xcrun altool --upload-app \
  --type ios \
  --file "$BUILD_DIR/Manas.ipa" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
echo "==> Uploaded. Processing usually takes a few minutes; check with: (cd ios && fastlane tf_status)"
