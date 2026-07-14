import Foundation

/// Pure aggregation and formatting math behind the usage strip and detail
/// panel. Everything here is deterministic given its inputs (records, dates,
/// calendar, locale) so it can be unit tested without an `AppStore`.
enum UsageMath {
    /// Totals for one calendar day of check-ins.
    struct DayTotals: Equatable, Sendable {
        var tokens: Int
        var costUSD: Double
        var checks: Int

        static let zero = DayTotals(tokens: 0, costUSD: 0, checks: 0)
    }

    /// Sums the records that fall on the same calendar day as `day`.
    static func totals(
        of records: [UsageRecord],
        on day: Date,
        calendar: Calendar = .current
    ) -> DayTotals {
        records
            .filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
            .reduce(into: .zero) { totals, record in
                totals.tokens += record.totalTokens
                totals.costUSD += record.costUSD
                totals.checks += 1
            }
    }

    /// A contiguous run of `days` calendar days ending on `end`, with empty
    /// days included and records sorted within each day — sparkline-ready.
    static func dailySeries(
        of records: [UsageRecord],
        days: Int = 7,
        endingOn end: Date,
        calendar: Calendar = .current
    ) -> [CheckInDay] {
        guard days > 0 else { return [] }
        let endDay = calendar.startOfDay(for: end)
        let byDay = Dictionary(grouping: records) { calendar.startOfDay(for: $0.timestamp) }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endDay) else { return nil }
            let dayRecords = (byDay[day] ?? []).sorted { $0.timestamp < $1.timestamp }
            return CheckInDay(date: day, records: dayRecords)
        }
    }

    /// How many of the strip's dots are filled: proportional to the soft
    /// daily budget, rounded up so any usage at all lights one dot, capped at
    /// `dotCount`. No budget means any usage fills the strip.
    static func filledDots(tokens: Int, budget: Int, dotCount: Int = 5) -> Int {
        guard dotCount > 0, tokens > 0 else { return 0 }
        guard budget > 0 else { return dotCount }
        let filled = (Double(tokens) / Double(budget) * Double(dotCount)).rounded(.up)
        return min(dotCount, max(1, Int(filled)))
    }

    /// Whether usage is close enough to the soft budget (~80%) that the
    /// strip should shift from muted gray to amber. The budget is a soft
    /// signal, never an alarm.
    static func isNearBudget(tokens: Int, budget: Int, threshold: Double = 0.8) -> Bool {
        guard tokens > 0 else { return false }
        guard budget > 0 else { return true }
        return Double(tokens) / Double(budget) >= threshold
    }

    /// 2140 → "2,140".
    static func formattedTokens(_ tokens: Int, locale: Locale = .current) -> String {
        tokens.formatted(IntegerFormatStyle<Int>(locale: locale))
    }

    /// "$0.03" style: two decimals normally, three for sub-cent costs so a
    /// cheap Haiku check doesn't display as free.
    static func formattedCost(_ usd: Double, locale: Locale = .current) -> String {
        let fractionDigits = usd != 0 && abs(usd) < 0.01 ? 3 : 2
        return usd.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(fractionDigits))
                .locale(locale)
        )
    }

    /// Display name for a stored model string: a `JudgeModel` raw value or a
    /// full API model id ("claude-haiku-4-5-...") both map to the friendly
    /// name; anything else passes through unchanged.
    static func modelDisplayName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        for model in JudgeModel.allCases where lowered.contains(model.rawValue) {
            return model.displayName
        }
        return raw
    }
}
