import SwiftUI

/// Footer bar: hairline top border, the usage strip slot on the left, and the
/// "Ask Claude" primary action on the right, with inline error text when a
/// judge pass fails.
struct MainFooterView: View {
    /// Injected by the integration layer; runs one judge pass for today.
    /// Nil until wired, which surfaces as inline error text on tap.
    var judgeToday: (@MainActor () async throws -> Void)?

    @State private var isJudging = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.hairline)
                .frame(height: 0.5)
            HStack(spacing: 10) {
                // Integration swaps this one view name for UsageStripView().
                FooterUsagePlaceholder()
                Spacer(minLength: 10)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isJudging {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    runJudge()
                } label: {
                    Label("Ask Claude", systemImage: "sparkles")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.manasAccent)
                .disabled(isJudging)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.manasBackground)
    }

    @MainActor
    private func runJudge() {
        guard !isJudging else { return }
        guard let judgeToday else {
            errorMessage = "Claude judge isn't connected yet"
            return
        }
        errorMessage = nil
        isJudging = true
        Task {
            do {
                try await judgeToday()
            } catch {
                errorMessage = error.localizedDescription
            }
            isJudging = false
        }
    }
}

/// Stand-in for the usage strip until the usage panel worker's
/// `UsageStripView` lands; the integration task swaps that single name in
/// `MainFooterView`. Shows the same headline numbers from `AppStore`.
struct FooterUsagePlaceholder: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var summary: String {
        let checks = store.checkCountToday
        let noun = checks == 1 ? "check" : "checks"
        return "\(store.tokensUsedToday.formatted()) tokens today · \(checks) \(noun)"
    }
}

#Preview("Footer") {
    MainFooterView(judgeToday: { try? await Task.sleep(for: .seconds(2)) })
        .environment(AppStore.previewJudged)
        .frame(width: 420)
}

#Preview("Footer, not wired") {
    MainFooterView()
        .environment(AppStore.previewEmpty)
        .frame(width: 420)
}
