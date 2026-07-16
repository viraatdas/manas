import AppKit
import SwiftUI
import XCTest

@testable import Manas

/// Layout behavior of the day-timeline sections, measured through real
/// NSHostingView layout passes (the same offscreen technique as the settings
/// popover tests).
@MainActor
final class TimelineLayoutTests: XCTestCase {
    func testEarlierIsHiddenWithoutPastDays() {
        let empty = fittingSize(of: EarlierSection(), store: .previewEmpty)
        XCTAssertEqual(empty.height, 0, accuracy: 0.5, "No past days — Earlier should render nothing.")
    }

    func testEarlierCollapsesToASingleRowAndExpandsToCards() {
        let store = AppStore.previewTimeline
        let collapsed = fittingSize(of: EarlierSection(), store: store)
        let expanded = fittingSize(of: EarlierSection(initiallyExpanded: true), store: store)

        XCTAssertGreaterThan(collapsed.height, 0, "Past days exist — the disclosure row should show.")
        XCTAssertLessThan(collapsed.height, 44, "Collapsed Earlier should be a single compact row.")
        XCTAssertGreaterThan(
            expanded.height, collapsed.height + 100,
            "Expanded Earlier should reveal one card per past day."
        )
    }

    func testUpcomingShowsOneSectionPerFutureDayPlusThePlanButton() {
        let planOnly = fittingSize(of: UpcomingSection(), store: .previewEmpty)
        let withDays = fittingSize(of: UpcomingSection(), store: .previewTimeline)

        XCTAssertGreaterThan(planOnly.height, 0, "The plan-a-day button shows even with nothing planned.")
        XCTAssertGreaterThan(
            withDays.height, planOnly.height + 100,
            "Planned future days should each add a day section above the button."
        )
    }

    /// Optional diagnostic: MANAS_TIMELINE_DUMP=<dir> writes PNGs of the
    /// timeline states for visual inspection.
    func testDumpTimelineSnapshots() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MANAS_TIMELINE_DUMP"] else {
            throw XCTSkip("Set MANAS_TIMELINE_DUMP=<dir> to dump timeline snapshots.")
        }
        let store = AppStore.previewTimeline
        try dump(
            ContentView().environment(store).frame(width: 520, height: 1560),
            name: "timeline-full", to: outDir
        )
        try dump(
            EarlierSection(initiallyExpanded: true)
                .environment(store)
                .padding(24)
                .frame(width: 520)
                .background(Color.manasBackground),
            name: "earlier-expanded", to: outDir
        )
        try dump(
            UpcomingSection()
                .environment(store)
                .padding(24)
                .frame(width: 520)
                .background(Color.manasBackground),
            name: "upcoming", to: outDir
        )
        try dump(
            PlanDayPicker { _ in }.background(Color.manasBackground),
            name: "plan-day-picker", to: outDir
        )
        let planned = Calendar.current.date(
            byAdding: .day, value: 3,
            to: Calendar.current.startOfDay(for: Date())
        )!
        try dump(
            UpcomingSection(initiallyPlanned: [planned])
                .environment(store)
                .padding(24)
                .frame(width: 520)
                .background(Color.manasBackground),
            name: "upcoming-planned-empty", to: outDir
        )
    }

    /// Optional diagnostic: MANAS_SEED_STATE=<path> writes the timeline
    /// preview data as a state file, for launching the app against scratch
    /// data (pair with MANAS_STATE_FILE and MANAS_DISABLE_AUTO_CHECKS).
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

    private func fittingSize(of view: some View, store: AppStore) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.environment(store).frame(width: 472)))
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
