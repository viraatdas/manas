import SwiftUI

/// Screen 2: the compact, always-visible footer strip — five budget dots and
/// today's totals in one caption line. The whole strip is a button that
/// toggles the expanded `UsageDetailPanel` (Screen 3) via `isExpanded`.
struct UsageStripView: View {
    @Environment(AppStore.self) private var store
    @Binding var isExpanded: Bool

    private static let dotCount = 5

    var body: some View {
        let totals = UsageMath.totals(of: store.usageRecords, on: Date())
        let filled = UsageMath.filledDots(
            tokens: totals.tokens,
            budget: store.dailyTokenBudget,
            dotCount: Self.dotCount
        )
        let nearBudget = UsageMath.isNearBudget(tokens: totals.tokens, budget: store.dailyTokenBudget)

        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                budgetDots(filled: filled, nearBudget: nearBudget)
                Text(summaryText(totals))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide usage details" : "Show usage details")
        .accessibilityLabel(accessibilityText(totals))
    }

    /// The soft-budget gauge: filled dots stay muted gray, shifting to amber
    /// once usage nears the budget — visual, never alarming.
    private func budgetDots(filled: Int, nearBudget: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.dotCount, id: \.self) { index in
                Circle()
                    .fill(
                        index < filled
                            ? (nearBudget ? Color.budgetAmber : Color(nsColor: .secondaryLabelColor))
                            : Color(nsColor: .quaternaryLabelColor)
                    )
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private func summaryText(_ totals: UsageMath.DayTotals) -> String {
        let tokensWord = totals.tokens == 1 ? "token" : "tokens"
        let checksWord = totals.checks == 1 ? "check" : "checks"
        return "\(UsageMath.formattedTokens(totals.tokens)) \(tokensWord) today"
            + " · \(UsageMath.formattedCost(totals.costUSD))"
            + " · \(totals.checks) \(checksWord)"
    }

    private func accessibilityText(_ totals: UsageMath.DayTotals) -> String {
        "\(summaryText(totals)). \(isExpanded ? "Collapses" : "Expands") usage details."
    }
}

extension Color {
    /// Muted amber for the near-budget dot state. Usage-strip only; the rest
    /// of the app keeps to the single coral accent.
    fileprivate static let budgetAmber = Color(red: 184 / 255, green: 133 / 255, blue: 31 / 255)
}

#Preview("Usage strip") {
    UsageStripView(isExpanded: .constant(false))
        .padding(12)
        .background(Color.manasBackground)
        .environment(UsageSampleData.store())
}

#Preview("Usage strip · near budget") {
    let store = UsageSampleData.store()
    store.dailyTokenBudget = 2_500
    return UsageStripView(isExpanded: .constant(false))
        .padding(12)
        .background(Color.manasBackground)
        .environment(store)
}

#Preview("Usage strip · empty day") {
    let store = UsageSampleData.store()
    store.usageRecords = []
    return UsageStripView(isExpanded: .constant(false))
        .padding(12)
        .background(Color.manasBackground)
        .environment(store)
}
