import Foundation
import XCTest

@testable import Manas

final class DayLabelTests: XCTestCase {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date()) }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
    }

    func testAdjacentDaysGetRelativeNames() {
        XCTAssertEqual(DayLabel.title(for: day(0)), "Today")
        XCTAssertEqual(DayLabel.title(for: day(1)), "Tomorrow")
        XCTAssertEqual(DayLabel.title(for: day(-1)), "Yesterday")
    }

    func testTimeOfDayDoesNotChangeTheLabel() {
        let lateTonight = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: today)!
        let earlyTomorrow = calendar.date(byAdding: .minute, value: 2, to: lateTonight)!
        XCTAssertEqual(DayLabel.title(for: lateTonight), "Today")
        XCTAssertEqual(DayLabel.title(for: earlyTomorrow), "Tomorrow")
    }

    func testFartherDaysReadAsWeekdayAndDate() {
        for offset in [-8, -2, 2, 30] {
            let label = DayLabel.title(for: day(offset))
            XCTAssertFalse(
                ["Today", "Tomorrow", "Yesterday"].contains(label),
                "Day at offset \(offset) should not get a relative name, got \(label)"
            )
            XCTAssertEqual(
                label,
                day(offset).formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                "Day at offset \(offset) should read as weekday + date"
            )
        }
    }

    func testRelativeNamesFollowTheReferenceDate() {
        let anchor = day(10)
        XCTAssertEqual(DayLabel.title(for: day(10), relativeTo: anchor), "Today")
        XCTAssertEqual(DayLabel.title(for: day(11), relativeTo: anchor), "Tomorrow")
        XCTAssertEqual(DayLabel.title(for: day(9), relativeTo: anchor), "Yesterday")
    }
}
