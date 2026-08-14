// Generates the Manas app icon artwork. Not part of the SPM package —
// run it standalone with the system toolchain, then rebuild the .icns from
// the two masters it writes:
//
//   swift assets/icon/render-icon.swift assets/icon
//   assets/icon/build-icns.sh
//
// The small master exists because the 40pt horizon line of the main mark
// disappears when resampled to 16px; the 16/32/64 slots get chunkier art.
//
// The tile is off-white and the mark is the accent, matching the app's own
// surfaces — an accent-flooded tile was tried (it survives a 20pt white
// System Settings row better) and rejected: the light tile is the better
// object everywhere the icon is actually looked at, and it is the one the iOS
// AppIcon carries too. The warm hairline is what keeps it from bleeding into
// white Finder and list backgrounds, so it is not optional here.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Manas design language (Sources/Manas/Design/Theme.swift)
let accent = Color(red: 216 / 255, green: 90 / 255, blue: 48 / 255)      // #D85A30
let offwhite = Color(red: 250 / 255, green: 248 / 255, blue: 245 / 255)  // #FAF8F5
let edge = Color(red: 232 / 255, green: 227 / 255, blue: 219 / 255)      // warm hairline

// macOS Big-Sur-onward canvas: 1024 canvas, 824pt continuous-corner squircle
// in off-white with a hairline edge, and no baked-in shadow.
//
// Baking one is the pre-Tahoe convention, but macOS 26 draws its own shadow
// under the art, so a baked shadow doubles up: a grey halo that rounds off the
// tile edge and drags the mark's contrast down with it. Measured, not assumed —
// a control bundle whose icns is a hard-edged full-bleed square (no shadow in
// the art at all) still comes back from NSWorkspace with a shadow, and the
// system rounds that square into a squircle by itself.
//
// That masking is also why full-bleed opaque art is the better shape on Tahoe:
// it fills the tile and the system supplies the silhouette. It is deliberately
// NOT what this draws. macOS 14 and 15 do no masking, and LSMinimumSystemVersion
// is 14.0, so full-bleed art would ship as a hard square to everyone below 26.
// Drawing our own squircle is correct on 14/15 and merely a little smaller than
// a native Tahoe icon on 26; the reverse trade would be a visible regression.
struct IconCanvas<Mark: View>: View {
    @ViewBuilder var mark: Mark
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185.4, style: .continuous)
                .fill(offwhite)
                .overlay(
                    RoundedRectangle(cornerRadius: 185.4, style: .continuous)
                        .strokeBorder(edge, lineWidth: 2)
                )
                .frame(width: 824, height: 824)
            mark
        }
        .frame(width: 1024, height: 1024)
    }
}

// The mark: a bindu over a horizon — the mind (manas) as a point of
// attention above the day it witnesses.
struct Mark: View {
    var body: some View {
        ZStack {
            Circle().fill(accent)
                .frame(width: 292, height: 292)
                .position(x: 512, y: 448)
            Capsule().fill(accent)
                .frame(width: 420, height: 40)
                .position(x: 512, y: 668)
        }
        .frame(width: 1024, height: 1024)
    }
}

// Same mark, chunkier proportions so the horizon survives 16/32/64px. Every
// feature is sized off the 16px worst case (64 canvas units to the pixel):
// a 352 bindu is 5.5px, the 88 horizon is 1.4px, and the 76 gap between them
// holds 1.2px of off-white — under those the two shapes fuse into one blob.
struct MarkSmall: View {
    var body: some View {
        ZStack {
            Circle().fill(accent)
                .frame(width: 352, height: 352)
                .position(x: 512, y: 424)
            Capsule().fill(accent)
                .frame(width: 512, height: 88)
                .position(x: 512, y: 720)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func render(_ view: some View, to path: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed for \(path)") }
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("cannot create destination \(path)") }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize failed \(path)") }
    print("wrote \(path) (\(cg.width)x\(cg.height))")
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
MainActor.assumeIsolated {
    render(IconCanvas { Mark() }, to: "\(outDir)/manas-1024.png")
    render(IconCanvas { MarkSmall() }, to: "\(outDir)/manas-small-1024.png")
}
