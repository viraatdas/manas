// Generates the installer window's backdrop. Not part of the SPM package —
// run it standalone with the system toolchain:
//
//   swift assets/dmg/render-dmg-background.swift assets/dmg
//
// It writes @1x and @2x PNGs; scripts/make-dmg.sh combines them into the
// multi-resolution TIFF Finder wants, so the window is not soft on a retina
// display.
//
// The geometry here and the icon positions in scripts/make-dmg.sh describe the
// same window and have to agree: the two circles below are where the app icon
// and the Applications alias land, and they are drawn so the icons look seated
// rather than dropped on top of a picture.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Manas design language (Sources/Manas/Design/Theme.swift)
let accent = Color(red: 216 / 255, green: 90 / 255, blue: 48 / 255)      // #D85A30
let offwhite = Color(red: 250 / 255, green: 248 / 255, blue: 245 / 255)  // #FAF8F5
let inkSecondary = Color(red: 122 / 255, green: 114 / 255, blue: 106 / 255)

let windowWidth: CGFloat = 660
let windowHeight: CGFloat = 420
let iconY: CGFloat = 196
let appIconX: CGFloat = 165
let applicationsX: CGFloat = 495

struct DMGBackground: View {
    var body: some View {
        ZStack {
            offwhite

            // The mark, small, at the top — the same bindu the app icon carries,
            // so the installer window is recognisably the thing being installed.
            VStack(spacing: 5) {
                Circle().fill(accent).frame(width: 26, height: 26)
                Capsule().fill(accent).frame(width: 38, height: 3.5)
            }
            .position(x: windowWidth / 2, y: 62)

            Text("Manas")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .position(x: windowWidth / 2, y: 112)

            // Seats for the two icons. Without them the icons float on a flat
            // field and the window reads as a folder rather than an installer.
            seat.position(x: appIconX, y: iconY)
            seat.position(x: applicationsX, y: iconY)

            arrow.position(x: windowWidth / 2, y: iconY)

            Text("Drag Manas into your Applications folder")
                .font(.system(size: 13))
                .foregroundStyle(inkSecondary)
                .position(x: windowWidth / 2, y: 330)
        }
        .frame(width: windowWidth, height: windowHeight)
    }

    private var seat: some View {
        Circle()
            .fill(Color.black.opacity(0.035))
            .frame(width: 118, height: 118)
    }

    /// Three chevrons fading rightwards — direction without an arrowhead
    /// heavy enough to compete with the icons either side of it.
    private var arrow: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { step in
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.28 + Double(step) * 0.22))
            }
        }
    }
}

@MainActor
func render(scale: CGFloat, to path: String) {
    let renderer = ImageRenderer(content: DMGBackground())
    renderer.scale = scale
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
    render(scale: 1, to: "\(outDir)/dmg-background.png")
    render(scale: 2, to: "\(outDir)/dmg-background@2x.png")
}
