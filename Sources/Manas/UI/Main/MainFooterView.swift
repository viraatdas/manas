import SwiftUI

/// Footer bar: hairline top border and the usage strip, with a quiet caption
/// when the last check-in failed. Clicking the strip slides the expanded
/// usage panel (Screen 3) out above the bar, inside the same window. Checks
/// themselves run automatically — the footer only reports.
struct MainFooterView: View {
    @Environment(AppStore.self) private var store
    @State private var isUsageExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var day: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            hairline
            if isUsageExpanded {
                VStack(spacing: 0) {
                    UsageDetailPanel(day: day)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: ContentView.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                    hairline
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 12) {
                UsageStripView(isExpanded: $isUsageExpanded, day: day)
                    // The strip keeps its single line; a long error message
                    // truncates instead.
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                if let error = store.lastCheckInError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(error)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: ContentView.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isUsageExpanded)
        .animation(.default, value: store.lastCheckInError)
        .background(Color.manasBackground)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: 0.5)
    }
}

#Preview("Footer") {
    MainFooterView()
        .environment(UsageSampleData.store())
        .frame(width: 520)
}

#Preview("Footer, check failed") {
    let store = AppStore.previewEmpty
    store.lastCheckInError = "Claude CLI not found. Install Claude Code, then try again."
    return MainFooterView()
        .environment(store)
        .frame(width: 520)
}
