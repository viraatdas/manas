import AppKit
import SwiftUI
import XCTest

@testable import Manas

@MainActor
final class TimelineLayoutTests: XCTestCase {
    func testPagerBuildsAContiguousWindowCenteredOnToday() {
        let calendar = Calendar.current
        let dates = DayPager.dates(around: Date(), radius: 4, calendar: calendar)

        XCTAssertEqual(dates.count, 9)
        XCTAssertTrue(calendar.isDateInToday(dates[4]))
        for pair in zip(dates, dates.dropFirst()) {
            XCTAssertEqual(calendar.dateComponents([.day], from: pair.0, to: pair.1).day, 1)
        }
    }

    func testPagerMovementNormalizesTimeAndMovesExactlyOneDay() {
        let calendar = Calendar.current
        let lateToday = calendar.date(bySettingHour: 23, minute: 45, second: 0, of: Date())!
        let previous = DayPager.moved(lateToday, by: -1, calendar: calendar)!
        let next = DayPager.moved(lateToday, by: 1, calendar: calendar)!

        XCTAssertEqual(previous, calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())))
        XCTAssertEqual(next, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())))
    }

    func testDateScopedPagesRenderEmptyAndPopulatedStates() {
        let store = AppStore.previewTimeline
        let today = Calendar.current.startOfDay(for: Date())
        let emptyFuture = Calendar.current.date(byAdding: .day, value: 10, to: today)!
        let populated = fittingSize(of: DayPageView(day: today), store: store)
        let empty = fittingSize(of: DayPageView(day: emptyFuture), store: store)

        XCTAssertGreaterThan(populated.height, 200)
        XCTAssertGreaterThan(empty.height, 150)
        XCTAssertNotEqual(populated.height, empty.height, "Each day must render its own store-backed content.")
    }

    func testSourceHealthPopoverIncludesPermissionRecoveryWithoutClipping() {
        let store = AppStore.previewEmpty
        store.sourceStatuses = [
            ActivitySourceStatus(source: .claude, state: .ready, activityCount: 2),
            ActivitySourceStatus(
                source: .messages,
                state: .permissionRequired,
                activityCount: 0,
                detail: "Allow Manas in Full Disk Access to read Messages."
            ),
        ]
        let size = fittingSize(of: SourceHealthPopover(), store: store, width: 330)

        XCTAssertEqual(size.width, 330, accuracy: 1)
        XCTAssertGreaterThan(size.height, 220)
    }

    /// Optional diagnostic: MANAS_TIMELINE_DUMP=<dir> writes the redesigned
    /// pager, adjacent days, and permission state for visual inspection.
    func testDumpTimelineSnapshots() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MANAS_TIMELINE_DUMP"] else {
            throw XCTSkip("Set MANAS_TIMELINE_DUMP=<dir> to dump timeline snapshots.")
        }
        let store = AppStore.previewTimeline
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        try dump(
            ContentView(showsOnboardingOnFirstLaunch: false, startsAutoCheckIns: false)
                .environment(store)
                .frame(width: 520, height: 760),
            name: "day-pager-today", to: outDir
        )
        try dump(
            DayPageView(day: calendar.date(byAdding: .day, value: -1, to: today)!)
                .environment(store)
                .frame(width: 520, height: 560),
            name: "day-pager-yesterday", to: outDir
        )
        try dump(
            DayPageView(day: calendar.date(byAdding: .day, value: 1, to: today)!)
                .environment(store)
                .frame(width: 520, height: 560),
            name: "day-pager-tomorrow", to: outDir
        )
        store.sourceStatuses[3] = ActivitySourceStatus(
            source: .screenTime,
            state: .permissionRequired,
            activityCount: 0,
            detail: "Allow Manas in Full Disk Access to read Screen Time."
        )
        try dump(
            SourceHealthPopover().environment(store),
            name: "source-health-permission", to: outDir
        )
    }

    /// Optional diagnostic: MANAS_SEED_STATE=<path> writes preview state for
    /// a real-window launch paired with MANAS_STATE_FILE and disabled checks.
    func testSeedScratchState() throws {
        guard let path = ProcessInfo.processInfo.environment["MANAS_SEED_STATE"] else {
            throw XCTSkip("Set MANAS_SEED_STATE=<path> to write a seeded state file.")
        }
        let source = AppStore.previewTimeline
        let target = AppStore(fileURL: URL(fileURLWithPath: path))
        target.todos = source.todos
        target.discoveredActivities = source.discoveredActivities
        target.usageRecords = source.usageRecords
        target.lastCheckedAt = source.lastCheckedAt
        target.syncedSourceCount = source.syncedSourceCount
        target.saveNow()
        print("SEEDED_STATE: \(path)")
    }

    private func fittingSize(
        of view: some View,
        store: AppStore,
        width: CGFloat = 472
    ) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.environment(store).frame(width: width)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func dump(_ view: some View, name: String, to outDir: String) throws {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("Could not create a bitmap for \(name).")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode \(name) as PNG.")
        }
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("TIMELINE_PNG: \(url.path) size: \(host.bounds.size)")
    }
}
