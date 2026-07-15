import AppKit
import SwiftUI
import XCTest

@testable import Manas

/// Layout regression tests for the settings popover. Under `swift test` the
/// process is not a .app bundle, so the popover shows the unbundled
/// launch-at-login caption ("Available when Manas runs as an installed
/// app.") — which is too long for one line at the popover's fixed width.
@MainActor
final class SettingsPopoverLayoutTests: XCTestCase {
    /// Popovers size themselves from the content's FIRST measurement. When
    /// the login-item caption was set in `onAppear`, that first measurement
    /// happened without it, the popover opened too short, and the caption
    /// was squeezed into one truncated line. The first ideal size must
    /// therefore already match the fully settled layout.
    func testFirstMeasurementAlreadyIncludesTheCaption() {
        let host = makeHost(of: SettingsPopover())
        let initial = host.fittingSize
        let settled = settle(host)

        XCTAssertEqual(
            initial, settled,
            "The popover's first measurement must already include the login-item caption; a caption that arrives after sizing gets truncated."
        )
    }

    /// The unbundled caption must wrap instead of truncating: the settled
    /// popover comes out at least one caption line taller than the same
    /// layout with every text forced to a single line.
    func testUnbundledCaptionWrapsInsteadOfTruncating() {
        let truncated = settle(makeHost(of: SettingsPopover().lineLimit(1)))
        let natural = settle(makeHost(of: SettingsPopover()))

        XCTAssertEqual(natural.width, truncated.width, accuracy: 0.5)
        XCTAssertGreaterThan(
            natural.height, truncated.height + 8,
            "Unbundled login-item caption should wrap to extra lines, not truncate to one."
        )
    }

    /// Optional diagnostic: MANAS_POPOVER_DUMP=<dir> writes a PNG of the
    /// popover at its natural size for visual inspection.
    func testDumpSnapshot() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MANAS_POPOVER_DUMP"] else {
            throw XCTSkip("Set MANAS_POPOVER_DUMP=<dir> to dump the popover snapshot.")
        }
        let host = makeHost(of: SettingsPopover())
        _ = settle(host)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("Could not create a bitmap for the popover view.")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode the popover bitmap as PNG.")
        }
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("settings-popover.png")
        try png.write(to: url)
        print("POPOVER_PNG: \(url.path) size: \(host.bounds.size)")
    }

    private func makeHost(of view: some View) -> NSHostingView<AnyView> {
        NSHostingView(rootView: AnyView(view.environment(AppStore.previewEmpty)))
    }

    /// Runs layout until the fitting size stops changing, so state set after
    /// the first measurement (e.g. in `onAppear`) is reflected in the result.
    private func settle(_ host: NSHostingView<AnyView>) -> CGSize {
        for _ in 0..<2 {
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        return host.fittingSize
    }
}
