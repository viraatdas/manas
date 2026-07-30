#!/usr/bin/env bash
# Ships a Manas release end to end. Build first, then release:
#
#   scripts/make-app.sh && scripts/release.sh 0.3.0
#
#   1. Notarizes dist/Manas.app and publishes v<version> to GitHub Releases
#      with the versioned DMG and checksums.
#   2. Mirrors that DMG as the stable Manas.dmg the website's download button
#      links to (releases/latest/download/Manas.dmg).
#   3. Regenerates the Sparkle appcast from the notarized DMG, signed with the
#      EdDSA private key in the login keychain.
#   4. Deploys the site, which is what publishes the appcast.
#
# Steps 3 and 4 are not optional extras: an installed copy only learns a new
# version exists when the appcast at SUFeedURL changes. Publishing a GitHub
# release without them ships a version that nobody auto-updates to.

set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: scripts/release.sh <x.y.z>" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="viraatdas/manas"
TAG="v$VERSION"
SITE_URL="https://manas.viraat.dev"
APP="$REPO_ROOT/dist/Manas.app"
DMG="$REPO_ROOT/dist/Manas-$VERSION.dmg"
NOTES="$REPO_ROOT/release-notes-$VERSION.md"
NOTARIZE="$HOME/.claude/skills/mac-notarize-release/scripts/notarize-release.sh"

[[ -d "$APP" ]] || { echo "error: $APP not found — run scripts/make-app.sh first" >&2; exit 1; }
[[ -f "$NOTES" ]] || { echo "error: $NOTES not found" >&2; exit 1; }
[[ -x "$NOTARIZE" ]] || { echo "error: notarize script not found at $NOTARIZE" >&2; exit 1; }

# The bundle's own version has to agree with the release, or installed copies
# compare against the wrong number and either re-offer an update forever or
# never offer one.
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || {
  echo "error: $APP is version $BUNDLE_VERSION, not $VERSION — bump VERSION in scripts/make-app.sh and rebuild" >&2
  exit 1
}

SPARKLE_BIN="$(dirname "$(find "$REPO_ROOT/.build/artifacts" -type f -name generate_appcast -print -quit)")"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || {
  echo "error: Sparkle tools not found — run swift build first" >&2; exit 1
}

echo "==> Notarizing and publishing $TAG"
"$NOTARIZE" --app "$APP" --version "$VERSION" --repo "$REPO" --notes "$NOTES"

echo "==> Mirroring the versioned DMG as Manas.dmg (the site's download link)"
cp "$DMG" "$REPO_ROOT/dist/Manas.dmg"
gh release upload "$TAG" "$REPO_ROOT/dist/Manas.dmg" --repo "$REPO" --clobber

# generate_appcast reads every archive in the directory it is given and builds
# one <item> per version, so it gets a directory holding only this release.
# The prefix is the tag's asset URL, which is where the DMG now lives.
echo "==> Signing the appcast"
STAGE="$REPO_ROOT/dist/appcast-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$DMG" "$STAGE/"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --full-release-notes-url "https://github.com/$REPO/releases" \
  --link "$SITE_URL" \
  -o "$REPO_ROOT/site/appcast.xml" \
  "$STAGE"
rm -rf "$STAGE"

echo "==> Deploying the site (publishes the appcast)"
(cd "$REPO_ROOT/site" && vercel deploy --prod --yes)

echo "==> Verifying the published feed"
PUBLISHED="$(curl -fsS "$SITE_URL/appcast.xml")"
grep -q "sparkle:shortVersionString=\"$VERSION\"" <<<"$PUBLISHED" \
  || { echo "error: $SITE_URL/appcast.xml does not advertise $VERSION" >&2; exit 1; }
grep -q "sparkle:edSignature" <<<"$PUBLISHED" \
  || { echo "error: published appcast is unsigned" >&2; exit 1; }

echo "==> Released $TAG — installed copies will pick it up within a day"
