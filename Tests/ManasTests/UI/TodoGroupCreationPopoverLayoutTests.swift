import AppKit
import SwiftUI
import XCTest

@testable import Manas

@MainActor
final class TodoGroupCreationPopoverLayoutTests: XCTestCase {
    func testCreatorRendersAtItsDesignedWidthWithoutLayoutChurn() {
        let host = makeHost()
        let initial = host.fittingSize
        host.frame = NSRect(origin: .zero, size: initial)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(initial.width, 286, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize, initial)
        XCTAssertGreaterThan(initial.height, 180)
    }

    /// Optional diagnostic:
    /// MANAS_GROUP_POPOVER_DUMP=<dir> writes the rendered creator as a PNG.
    func testDumpSnapshot() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MANAS_GROUP_POPOVER_DUMP"] else {
            throw XCTSkip("Set MANAS_GROUP_POPOVER_DUMP=<dir> to dump the group creator.")
        }
        let host = makeHost()
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("Could not create a bitmap for the group creator.")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode the group creator.")
        }
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("group-creator.png")
        try png.write(to: url)
        print("GROUP_POPOVER_PNG: \(url.path) size: \(host.bounds.size)")
    }

    private func makeHost() -> NSHostingView<AnyView> {
        NSHostingView(rootView: AnyView(
            TodoGroupCreationPopover(onCreated: { _ in }, onCancel: {})
                .environment(AppStore.previewEmpty)
                .background(Color.manasBackground)
        ))
    }
}
