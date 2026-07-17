import AppKit
import SwiftUI
import XCTest

@testable import Manas

@MainActor
final class TimelineLayoutTests: XCTestCase {
    func testFeedOrdersPastOldestFirstThenTodayThenFuture() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let past = [
            calendar.date(byAdding: .day, value: -1, to: today)!,
            calendar.date(byAdding: .day, value: -4, to: today)!,
        ]
        let days = DayFeed.days(past: past, today: today, futureHorizon: 7, calendar: calendar)

        // Oldest past first, Today in the middle, then seven future days.
        XCTAssertEqual(days.count, 2 + 1 + 7)
        XCTAssertEqual(days.prefix(2).map(\.kind), [.past, .past])
        XCTAssertEqual(days[0].date, calendar.date(byAdding: .day, value: -4, to: today))
        XCTAssertEqual(days[1].date, calendar.date(byAdding: .day, value: -1, to: today))
        XCTAssertEqual(days[2].kind, .today)
        XCTAssertEqual(days[2].date, today)
        XCTAssertTrue(days.suffix(7).allSatisfy { $0.kind == .future })
        XCTAssertEqual(days[3].date, calendar.date(byAdding: .day, value: 1, to: today))
    }

    func testFeedFutureHorizonAlwaysMaterializesTomorrowOnward() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = DayFeed.days(past: [], today: today, futureHorizon: 14, calendar: calendar)

        XCTAssertEqual(days.first?.kind, .today, "with no past todos, Today leads the feed")
        XCTAssertEqual(days.filter { $0.kind == .future }.count, 14)
    }

    func testDayFeedSectionRendersEmptyAndPopulatedStates() {
        let store = AppStore.previewTimeline
        let today = Calendar.current.startOfDay(for: Date())
        let emptyFuture = Calendar.current.date(byAdding: .day, value: 10, to: today)!
        let populated = fittingSize(
            of: DayFeedSection(feedDay: FeedDay(date: today, kind: .today)), store: store
        )
        let empty = fittingSize(
            of: DayFeedSection(feedDay: FeedDay(date: emptyFuture, kind: .future)), store: store
        )

        XCTAssertGreaterThan(populated.height, 200)
        XCTAssertGreaterThan(empty.height, 30, "an empty future day still shows its add field")
        XCTAssertNotEqual(populated.height, empty.height, "Each day renders its own store-backed content.")
    }

    func testGroupedTodoListRendersAtCompactContentWidth() {
        let store = AppStore.previewJudged
        let size = fittingSize(of: TodoListSection(), store: store, width: 412)

        XCTAssertEqual(
            store.todoGroups(on: Date()).map(\.group), [nil, "Manas", "Launch"],
            "the ungrouped cluster leads, then the judge's labeled groups"
        )
        XCTAssertEqual(size.width, 412, accuracy: 1)
        XCTAssertGreaterThan(size.height, 300, "the ungrouped cluster and both group cards contribute to layout")
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
            name: "day-feed-today", to: outDir
        )
        try dump(
            DayFeedSection(feedDay: FeedDay(date: calendar.date(byAdding: .day, value: -1, to: today)!, kind: .past))
                .environment(store)
                .frame(width: 520, height: 560),
            name: "day-feed-yesterday", to: outDir
        )
        try dump(
            DayFeedSection(feedDay: FeedDay(date: calendar.date(byAdding: .day, value: 1, to: today)!, kind: .future))
                .environment(store)
                .frame(width: 520, height: 560),
            name: "day-feed-tomorrow", to: outDir
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
