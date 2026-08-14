#!/usr/bin/env bash
# Rebuilds assets/icon/Manas.icns from the two masters render-icon.swift
# writes. Run it after the renderer:
#
#   swift assets/icon/render-icon.swift assets/icon
#   assets/icon/build-icns.sh
#
# The 16/32/64 slots come from the small master and everything above it from
# the main one — see render-icon.swift for why the small art exists.

set -euo pipefail

ICON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMALL="$ICON_DIR/manas-small-1024.png"
LARGE="$ICON_DIR/manas-1024.png"
for master in "$SMALL" "$LARGE"; do
  [[ -f "$master" ]] || { echo "error: missing $master — run render-icon.swift first" >&2; exit 1; }
done

ICONSET="$(mktemp -d)/Manas.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

# slot:size:master — the @2x slot of one size and the 1x slot of the next are
# the same pixel count on purpose; macOS picks between them by scale factor.
while IFS=: read -r slot size master; do
  src="$ICON_DIR/$master"
  sips -z "$size" "$size" "$src" --out "$ICONSET/$slot.png" >/dev/null
done <<'SLOTS'
icon_16x16:16:manas-small-1024.png
icon_16x16@2x:32:manas-small-1024.png
icon_32x32:32:manas-small-1024.png
icon_32x32@2x:64:manas-small-1024.png
icon_128x128:128:manas-1024.png
icon_128x128@2x:256:manas-1024.png
icon_256x256:256:manas-1024.png
icon_256x256@2x:512:manas-1024.png
icon_512x512:512:manas-1024.png
icon_512x512@2x:1024:manas-1024.png
SLOTS

iconutil -c icns "$ICONSET" -o "$ICON_DIR/Manas.icns"
echo "==> wrote $ICON_DIR/Manas.icns"
