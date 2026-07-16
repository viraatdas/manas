import Charts
import SwiftUI

/// Screen 3: the expanded usage view — today's total as a metric card, a
/// per-check-in table, and a 7-day sparkline. Lives inside the window as a
/// slide-down panel above the footer strip (see `MainFooterView`), never a
/// separate window.
struct UsageDetailPanel: View {
    @Environment(AppStore.self) private var store
    var day: Date = Date()

    var body: some View {
        let totals = UsageMath.totals(of: store.usageRecords, on: day)
        let dayRecords = store.records(on: day).sorted { $0.timestamp > $1.timestamp }
        let series = UsageMath.dailySeries(of: store.usageRecords, days: 7, endingOn: day)

        VStack(alignment: .leading, spacing: 14) {
            metricCard(totals)
            sessionTable(dayRecords)
            sparkline(series)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.manasBackground)
    }

    // MARK: - Today's total

    private func metricCard(_ totals: UsageMath.DayTotals) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(DayLabel.title(for: day)) total")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(UsageMath.formattedTokens(totals.tokens))
                    .font(.title)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("tokens")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(UsageMath.formattedCost(totals.costUSD)) · \(totals.checks) \(totals.checks == 1 ? "check" : "checks")")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .manasCard()
    }

    // MARK: - Per-session table

    private func sessionTable(_ records: [UsageRecord]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Check-ins · \(DayLabel.title(for: day).lowercased())")
                .font(.caption)
                .foregroundStyle(.secondary)
            if records.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(emptyCheckInCopy)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            } else if records.count > 6 {
                ScrollView {
                    sessionRows(records)
                }
                .frame(maxHeight: 168)
            } else {
                sessionRows(records)
            }
        }
    }

    private var emptyCheckInCopy: String {
        Calendar.current.isDateInToday(day)
            ? "No check-ins yet — the first one runs on its own"
            : "No check-ins were recorded for this day"
    }

    private func sessionRows(_ records: [UsageRecord]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                sessionRow(record)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(
                        index.isMultiple(of: 2) ? Color.clear : Color.surface1,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            }
        }
    }

    private func sessionRow(_ record: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .leading)
                Text(UsageMath.modelDisplayName(record.model))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(UsageMath.formattedTokens(record.tokensIn)) in · \(UsageMath.formattedTokens(record.tokensOut)) out")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(UsageMath.formattedCost(record.costUSD))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
            Text(record.summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 64)
        }
        .font(.caption)
    }

    // MARK: - 7-day sparkline

    private func sparkline(_ series: [CheckInDay]) -> some View {
        let todayDate = series.last?.date
        let maxTokens = series.map(\.totalTokens).max() ?? 0
        // The x-domain must run through the END of the last day, or the
        // final bar and its label get clipped at the trailing edge.
        let calendar = Calendar.current
        let domainStart = series.first?.date ?? calendar.startOfDay(for: Date())
        let domainEnd = calendar.date(byAdding: .day, value: 1, to: todayDate ?? domainStart) ?? domainStart
        return VStack(alignment: .leading, spacing: 4) {
            Text("Last 7 days")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(series) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Tokens", day.totalTokens)
                )
                .foregroundStyle(day.date == todayDate ? Color.manasAccent : Color.manasAccent.opacity(0.45))
                .cornerRadius(2)
            }
            .chartXAxis {
                // Marks sit at each day's noon so every label lands under
                // its bar; a centered label on the last tick gets dropped
                // at the trailing edge.
                AxisMarks(values: series.compactMap {
                    calendar.date(byAdding: .hour, value: 12, to: $0.date)
                }) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), collisionResolution: .disabled)
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
            .chartYAxis(.hidden)
            .chartXScale(domain: domainStart...domainEnd)
            .chartYScale(domain: 0...Double(max(1, maxTokens)))
            .frame(height: 44)
            .accessibilityLabel("Token usage for the last 7 days")
        }
    }

}

#Preview("Usage detail panel") {
    UsageDetailPanel()
        .frame(width: 420)
        .environment(UsageSampleData.store())
}

#Preview("Usage detail panel · empty day") {
    let store = UsageSampleData.store()
    store.usageRecords = []
    return UsageDetailPanel()
        .frame(width: 420)
        .environment(store)
}
