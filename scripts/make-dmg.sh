#!/usr/bin/env bash
# Builds the branded installer disk image: the app on the left, an Applications
# alias on the right, seated on assets/dmg's backdrop.
#
#   scripts/make-dmg.sh <app> <out.dmg> [volume name]
#
# Written here rather than left to the notarize skill because the layout is a
# Manas design decision: the icon positions have to match the seats drawn in
# assets/dmg/render-dmg-background.swift, and only this repo knows them.
#
# The shape of the work is forced by how Finder stores window settings. They
# live in the volume's own .DS_Store, so they can only be written by mounting a
# READ-WRITE image, telling Finder about it, letting Finder flush, and only then
# compressing to the read-only image that ships. Building a UDZO image directly
# from a folder — which is the obvious way, and what the plain pipeline does —
# produces a window with no background and default icon positions.

set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <out.dmg> [volume name]}"
OUT="${2:?usage: make-dmg.sh <app> <out.dmg> [volume name]}"
VOLUME="${3:-Manas}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$REPO_ROOT/assets/dmg"
APP_NAME="$(basename "$APP")"

# Must agree with render-dmg-background.swift.
WINDOW_W=660
WINDOW_H=420
ICON_Y=196
APP_ICON_X=165
APPLICATIONS_X=495
ICON_SIZE=104

[[ -d "$APP" ]] || { echo "error: no app at $APP" >&2; exit 1; }
for image in "$ASSETS/dmg-background.png" "$ASSETS/dmg-background@2x.png"; do
  [[ -f "$image" ]] || {
    echo "error: missing $image — run: swift assets/dmg/render-dmg-background.swift assets/dmg" >&2
    exit 1
  }
done

STAGE="$(mktemp -d)"
SCRATCH="$(mktemp -d)/rw.dmg"
MOUNT="/Volumes/$VOLUME"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$STAGE" "$(dirname "$SCRATCH")"
}
trap cleanup EXIT

echo "==> Staging $APP_NAME"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
# A multi-representation TIFF so the backdrop is sharp on retina. tiffutil
# writes the 1x and 2x reps into one file; Finder picks per display.
tiffutil -cathidpicheck "$ASSETS/dmg-background.png" "$ASSETS/dmg-background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null

# A stale mount from an interrupted run would make the copy land in the wrong
# place and the layout silently apply to nothing.
hdiutil detach "$MOUNT" -quiet 2>/dev/null || true

echo "==> Creating a writable image"
rm -f "$SCRATCH"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ \
  -format UDRW -ov "$SCRATCH" >/dev/null
hdiutil attach "$SCRATCH" -noautoopen -quiet
# Finder needs the volume to be there before it is told anything about it.
for _ in $(seq 1 40); do [[ -d "$MOUNT" ]] && break; sleep 0.25; done
[[ -d "$MOUNT" ]] || { echo "error: $MOUNT never appeared" >&2; exit 1; }

echo "==> Laying out the window"
osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- Finder measures the window frame, not the content, so the numbers
        -- here are the background's size plus the title bar it draws above it.
        set the bounds of container window to {200, 140, ${WINDOW_W} + 200, ${WINDOW_H} + 160}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$APP_NAME" of container window to {$APP_ICON_X, $ICON_Y}
        set position of item "Applications" of container window to {$APPLICATIONS_X, $ICON_Y}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Finder writes .DS_Store lazily; detaching before it lands loses the layout.
sync
sleep 2

echo "==> Compressing"
hdiutil detach "$MOUNT" -quiet
rm -f "$OUT"
hdiutil convert "$SCRATCH" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "==> wrote $OUT"
