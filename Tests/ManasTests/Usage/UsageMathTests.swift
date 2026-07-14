import XCTest
@testable import Manas

final class UsageMathTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    /// Fixed calendar so day bucketing doesn't depend on the machine's zone.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func record(
        at timestamp: Date,
        tokensIn: Int = 100,
        tokensOut: Int = 50,
        costUSD: Double = 0.01,
        model: String = "haiku",
        summary: String = "judged"
    ) -> UsageRecord {
        UsageRecord(
            timestamp: timestamp, model: model,
            tokensIn: tokensIn, tokensOut: tokensOut,
            costUSD: costUSD, summary: summary
        )
    }

    // MARK: - Day totals

    func testTotalsOfEmptyRecordsIsZero() {
        let totals = UsageMath.totals(of: [], on: date(2026, 7, 14), calendar: calendar)
        XCTAssertEqual(totals, .zero)
    }

    func testTotalsSumsTokensInAndOutCostAndChecks() {
        let day = date(2026, 7, 14)
        let records = [
            record(at: date(2026, 7, 14, 8, 5), tokensIn: 320, tokensOut: 60, costUSD: 0.006),
            record(at: date(2026, 7, 14, 10, 41), tokensIn: 410, tokensOut: 75, costUSD: 0.007),
            record(at: date(2026, 7, 14, 12, 58), tokensIn: 460, tokensOut: 90, costUSD: 0.008),
            record(at: date(2026, 7, 14, 14, 14), tokensIn: 585, tokensOut: 140, costUSD: 0.009),
        ]
        let totals = UsageMath.totals(of: records, on: day, calendar: calendar)
        XCTAssertEqual(totals.tokens, 2_140)
        XCTAssertEqual(totals.costUSD, 0.03, accuracy: 1e-9)
        XCTAssertEqual(totals.checks, 4)
    }

    func testTotalsIgnoresOtherDays() {
        let records = [
            record(at: date(2026, 7, 13, 23, 59), tokensIn: 1_000, tokensOut: 0),
            record(at: date(2026, 7, 14, 0, 0), tokensIn: 200, tokensOut: 40),
            record(at: date(2026, 7, 15, 0, 0), tokensIn: 3_000, tokensOut: 0),
        ]
        let totals = UsageMath.totals(of: records, on: date(2026, 7, 14, 18), calendar: calendar)
        XCTAssertEqual(totals.tokens, 240)
        XCTAssertEqual(totals.checks, 1)
    }

    // MARK: - 7-day series

    func testDailySeriesFillsEmptyDaysAndEndsOnRequestedDay() {
        let records = [
            record(at: date(2026, 7, 10), tokensIn: 500, tokensOut: 100),
            record(at: date(2026, 7, 14), tokensIn: 300, tokensOut: 50),
        ]
        let series = UsageMath.dailySeries(of: records, days: 7, endingOn: date(2026, 7, 14, 15), calendar: calendar)

        XCTAssertEqual(series.count, 7)
        XCTAssertEqual(series.first?.date, calendar.startOfDay(for: date(2026, 7, 8)))
        XCTAssertEqual(series.last?.date, calendar.startOfDay(for: date(2026, 7, 14)))
        XCTAssertEqual(series.map(\.totalTokens), [0, 0, 600, 0, 0, 0, 350])
        // Contiguous, ascending days.
        for (previous, next) in zip(series, series.dropFirst()) {
            XCTAssertEqual(calendar.date(byAdding: .day, value: 1, to: previous.date), next.date)
        }
    }

    func testDailySeriesExcludesRecordsOutsideWindow() {
        let records = [
            record(at: date(2026, 7, 7), tokensIn: 9_000, tokensOut: 0),
            record(at: date(2026, 7, 15), tokensIn: 9_000, tokensOut: 0),
            record(at: date(2026, 7, 12), tokensIn: 100, tokensOut: 20),
        ]
        let series = UsageMath.dailySeries(of: records, days: 7, endingOn: date(2026, 7, 14), calendar: calendar)
        XCTAssertEqual(series.reduce(0) { $0 + $1.totalTokens }, 120)
    }

    func testDailySeriesSortsRecordsWithinDay() {
        let later = record(at: date(2026, 7, 14, 16, 0), tokensIn: 2)
        let earlier = record(at: date(2026, 7, 14, 9, 0), tokensIn: 1)
        let series = UsageMath.dailySeries(of: [later, earlier], days: 1, endingOn: date(2026, 7, 14), calendar: calendar)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].records.map(\.tokensIn), [1, 2])
    }

    func testDailySeriesWithNonPositiveDaysIsEmpty() {
        XCTAssertTrue(UsageMath.dailySeries(of: [], days: 0, endingOn: date(2026, 7, 14), calendar: calendar).isEmpty)
        XCTAssertTrue(UsageMath.dailySeries(of: [], days: -3, endingOn: date(2026, 7, 14), calendar: calendar).isEmpty)
    }

    // MARK: - Budget dots

    func testFilledDotsIsZeroWithoutUsage() {
        XCTAssertEqual(UsageMath.filledDots(tokens: 0, budget: 10_000), 0)
        XCTAssertEqual(UsageMath.filledDots(tokens: -5, budget: 10_000), 0)
    }

    func testFilledDotsRoundsUpSoAnyUsageShows() {
        XCTAssertEqual(UsageMath.filledDots(tokens: 1, budget: 10_000), 1)
        XCTAssertEqual(UsageMath.filledDots(tokens: 2_140, budget: 10_000), 2) // 1.07 dots → 2
        XCTAssertEqual(UsageMath.filledDots(tokens: 4_000, budget: 10_000), 2) // exactly 2
        XCTAssertEqual(UsageMath.filledDots(tokens: 8_000, budget: 10_000), 4)
        XCTAssertEqual(UsageMath.filledDots(tokens: 8_001, budget: 10_000), 5)
    }

    func testFilledDotsCapsAtDotCount() {
        XCTAssertEqual(UsageMath.filledDots(tokens: 10_000, budget: 10_000), 5)
        XCTAssertEqual(UsageMath.filledDots(tokens: 99_000, budget: 10_000), 5)
    }

    func testFilledDotsWithoutBudgetFillsOnAnyUsage() {
        XCTAssertEqual(UsageMath.filledDots(tokens: 10, budget: 0), 5)
        XCTAssertEqual(UsageMath.filledDots(tokens: 0, budget: 0), 0)
    }

    func testFilledDotsRespectsDotCount() {
        XCTAssertEqual(UsageMath.filledDots(tokens: 5_000, budget: 10_000, dotCount: 10), 5)
        XCTAssertEqual(UsageMath.filledDots(tokens: 5_000, budget: 10_000, dotCount: 0), 0)
    }

    // MARK: - Near budget

    func testIsNearBudgetAtEightyPercent() {
        XCTAssertFalse(UsageMath.isNearBudget(tokens: 7_999, budget: 10_000))
        XCTAssertTrue(UsageMath.isNearBudget(tokens: 8_000, budget: 10_000))
        XCTAssertTrue(UsageMath.isNearBudget(tokens: 12_000, budget: 10_000))
    }

    func testIsNearBudgetEdgeCases() {
        XCTAssertFalse(UsageMath.isNearBudget(tokens: 0, budget: 10_000))
        XCTAssertFalse(UsageMath.isNearBudget(tokens: 0, budget: 0))
        XCTAssertTrue(UsageMath.isNearBudget(tokens: 1, budget: 0))
    }

    // MARK: - Formatting

    func testFormattedTokensUsesThousandsSeparators() {
        XCTAssertEqual(UsageMath.formattedTokens(0, locale: enUS), "0")
        XCTAssertEqual(UsageMath.formattedTokens(999, locale: enUS), "999")
        XCTAssertEqual(UsageMath.formattedTokens(2_140, locale: enUS), "2,140")
        XCTAssertEqual(UsageMath.formattedTokens(1_234_567, locale: enUS), "1,234,567")
    }

    func testFormattedCostUsesTwoDecimals() {
        XCTAssertEqual(UsageMath.formattedCost(0, locale: enUS), "$0.00")
        XCTAssertEqual(UsageMath.formattedCost(0.03, locale: enUS), "$0.03")
        XCTAssertEqual(UsageMath.formattedCost(0.034, locale: enUS), "$0.03")
        XCTAssertEqual(UsageMath.formattedCost(1.238, locale: enUS), "$1.24")
        XCTAssertEqual(UsageMath.formattedCost(12.5, locale: enUS), "$12.50")
    }

    func testFormattedCostShowsSubCentCostsWithThreeDecimals() {
        XCTAssertEqual(UsageMath.formattedCost(0.003, locale: enUS), "$0.003")
        XCTAssertEqual(UsageMath.formattedCost(0.0099, locale: enUS), "$0.010")
    }

    // MARK: - Model names

    func testModelDisplayNameMapsRawValuesAndAPIIds() {
        XCTAssertEqual(UsageMath.modelDisplayName("haiku"), "Haiku")
        XCTAssertEqual(UsageMath.modelDisplayName("sonnet"), "Sonnet")
        XCTAssertEqual(UsageMath.modelDisplayName("claude-haiku-4-5-20251001"), "Haiku")
        XCTAssertEqual(UsageMath.modelDisplayName("SONNET"), "Sonnet")
        XCTAssertEqual(UsageMath.modelDisplayName("some-other-model"), "some-other-model")
    }
}
