import AppKit
import SwiftUI
import XCTest

@testable import Manas

@MainActor
final class OnboardingLayoutTests: XCTestCase {
    func testEveryPageRendersAtTheMinimumSupportedWindowSize() {
        for page in ManasOnboardingPage.allCases {
            let host = hostView(page: page, width: 460, height: 620)
            XCTAssertEqual(host.bounds.width, 460, accuracy: 1, "\(page) width")
            XCTAssertEqual(host.bounds.height, 620, accuracy: 1, "\(page) height")
            XCTAssertNotNil(
                host.bitmapImageRepForCachingDisplay(in: host.bounds),
                "\(page) should render into the minimum window"
            )
        }
    }

    func testEveryPageRendersAtTheDefaultWindowSize() {
        for page in ManasOnboardingPage.allCases {
            let host = hostView(page: page, width: 560, height: 780)
            XCTAssertEqual(host.bounds.width, 560, accuracy: 1, "\(page) width")
            XCTAssertEqual(host.bounds.height, 780, accuracy: 1, "\(page) height")
        }
    }

    /// Optional visual diagnostic used by the real-window verification pass.
    /// MANAS_ONBOARDING_DUMP=<dir> writes all three first-run pages as PNGs.
    func testDumpOnboardingSnapshots() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MANAS_ONBOARDING_DUMP"] else {
            throw XCTSkip("Set MANAS_ONBOARDING_DUMP=<dir> to dump onboarding snapshots.")
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outDir, isDirectory: true),
            withIntermediateDirectories: true
        )

        for page in ManasOnboardingPage.allCases {
            let host = hostView(page: page, width: 560, height: 780)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                return XCTFail("Could not create a bitmap for \(page)")
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                return XCTFail("Could not encode \(page)")
            }
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("onboarding-\(page.rawValue).png")
            try png.write(to: url)
            print("ONBOARDING_PNG: \(url.path)")
        }
    }

    private func hostView(page: ManasOnboardingPage, width: CGFloat, height: CGFloat) -> NSHostingView<AnyView> {
        let store = AppStore.previewJudged
        store.sourceStatuses[3] = ActivitySourceStatus(
            source: .screenTime,
            state: .permissionRequired,
            activityCount: 0
        )
        store.sourceStatuses[4] = ActivitySourceStatus(
            source: .messages,
            state: .permissionRequired,
            activityCount: 0
        )
        let view = OnboardingView(initialPage: page, probesSources: false, finish: {})
            .environment(store)
            .frame(width: width, height: height)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return host
    }
}
