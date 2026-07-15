// Generates the Manas app icon artwork. Not part of the SPM package —
// run it standalone with the system toolchain:
//
//   swift assets/icon/render-icon.swift assets/icon
//
// then rebuild the .icns from the two masters it writes:
//
//   ICONSET=$(mktemp -d)/Manas.iconset && mkdir -p "$ICONSET"
//   sips -z 16 16   assets/icon/manas-small-1024.png --out "$ICONSET/icon_16x16.png"
//   sips -z 32 32   assets/icon/manas-small-1024.png --out "$ICONSET/icon_16x16@2x.png"
//   sips -z 32 32   assets/icon/manas-small-1024.png --out "$ICONSET/icon_32x32.png"
//   sips -z 64 64   assets/icon/manas-small-1024.png --out "$ICONSET/icon_32x32@2x.png"
//   sips -z 128 128 assets/icon/manas-1024.png --out "$ICONSET/icon_128x128.png"
//   sips -z 256 256 assets/icon/manas-1024.png --out "$ICONSET/icon_128x128@2x.png"
//   sips -z 256 256 assets/icon/manas-1024.png --out "$ICONSET/icon_256x256.png"
//   sips -z 512 512 assets/icon/manas-1024.png --out "$ICONSET/icon_256x256@2x.png"
//   sips -z 512 512 assets/icon/manas-1024.png --out "$ICONSET/icon_512x512.png"
//   cp assets/icon/manas-1024.png "$ICONSET/icon_512x512@2x.png"
//   iconutil -c icns "$ICONSET" -o assets/icon/Manas.icns
//
// The small master exists because the 40pt horizon line of the main mark
// disappears when resampled to 16px; the 16/32/64 slots get chunkier art.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Manas design language (Sources/Manas/Design/Theme.swift)
let accent = Color(red: 216 / 255, green: 90 / 255, blue: 48 / 255)      // #D85A30
let offwhite = Color(red: 250 / 255, green: 248 / 255, blue: 245 / 255)  // #FAF8F5
let edge = Color(red: 232 / 255, green: 227 / 255, blue: 219 / 255)      // warm hairline

// macOS Big-Sur-onward canvas: 1024 canvas, 824pt continuous-corner squircle,
// subtle baked-in shadow (convention), hairline edge so the light tile reads
// against white Finder backgrounds.
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
                .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 7)
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

// Same mark, chunkier proportions so the horizon survives 16/32/64px.
struct MarkSmall: View {
    var body: some View {
        ZStack {
            Circle().fill(accent)
                .frame(width: 340, height: 340)
                .position(x: 512, y: 430)
            Capsule().fill(accent)
                .frame(width: 490, height: 76)
                .position(x: 512, y: 688)
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
