import AppKit
import SwiftUI

extension Notification.Name {
    static let showManasOnboarding = Notification.Name("dev.viraat.manas.show-onboarding")
}

enum ManasOnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case sources
    case firstTodo

    var id: Int { rawValue }
}

/// A short, full-window first-run flow. It demonstrates the product, checks
/// real source access without spending tokens, and lets the user create a
/// real first todo before the automatic judge starts.
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: ManasOnboardingPage
    @State private var firstTodo = ""
    @State private var movesForward = true
    @FocusState private var shellFocused: Bool
    @FocusState private var todoFocused: Bool

    private let probesSources: Bool
    var finish: () -> Void

    init(
        initialPage: ManasOnboardingPage = .welcome,
        probesSources: Bool = true,
        finish: @escaping () -> Void
    ) {
        _page = State(initialValue: initialPage)
        self.probesSources = probesSources
        self.finish = finish
    }

    var body: some View {
        ZStack {
            onboardingBackground

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                ScrollView {
                    pageContent
                        .id(page)
                        .transition(pageTransition)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusable()
        .focused($shellFocused)
        .focusEffectDisabled()
        .onAppear { shellFocused = true }
        .onKeyPress(.rightArrow) {
            guard !todoFocused else { return .ignored }
            advance()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard !todoFocused else { return .ignored }
            retreat()
            return .handled
        }
        .onKeyPress(.escape) {
            finish()
            return .handled
        }
        .accessibilityAddTraits(.isModal)
    }

    private var onboardingBackground: some View {
        ZStack(alignment: .top) {
            Color.manasBackground
            Color.manasAccent.opacity(0.055)
                .frame(height: 190)
            Rectangle()
                .fill(Color.hairline.opacity(0.55))
                .frame(height: 0.5)
                .padding(.top, 190)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 9) {
            ManasBrandMark(size: 30)
            Text("Manas")
                .font(.headline)

            Spacer()

            Button("Skip") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close the welcome tour")
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .welcome:
            WelcomeOnboardingPage()
        case .sources:
            SourceSetupOnboardingPage(probesSources: probesSources)
        case .firstTodo:
            FirstTodoOnboardingPage(
                text: $firstTodo,
                isFocused: $todoFocused,
                submit: complete
            )
        }
    }

    private var footer: some View {
        HStack {
            Group {
                if page == .welcome {
                    Color.clear
                } else {
                    Button("Back") { retreat() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            // A fixed height matters here: an unconstrained Color.clear is
            // vertically greedy and would pull the footer into the page.
            .frame(width: 100, height: 34, alignment: .leading)

            Spacer()

            HStack(spacing: 7) {
                ForEach(ManasOnboardingPage.allCases) { candidate in
                    Button {
                        go(to: candidate)
                    } label: {
                        Capsule()
                            .fill(candidate == page ? Color.manasAccent : Color.hairline)
                            .frame(width: candidate == page ? 18 : 7, height: 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Step \(candidate.rawValue + 1) of \(ManasOnboardingPage.allCases.count)")
                    .accessibilityAddTraits(candidate == page ? .isSelected : [])
                }
            }

            Spacer()

            Button(page == .firstTodo ? "Start my day" : "Continue") {
                page == .firstTodo ? complete() : advance()
            }
            .buttonStyle(.borderedProminent)
            .tint(.manasAccent)
            .controlSize(.large)
            .frame(width: 100, alignment: .trailing)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: movesForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movesForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func advance() {
        guard let next = ManasOnboardingPage(rawValue: page.rawValue + 1) else { return }
        go(to: next)
    }

    private func retreat() {
        guard let previous = ManasOnboardingPage(rawValue: page.rawValue - 1) else { return }
        go(to: previous)
    }

    private func go(to destination: ManasOnboardingPage) {
        guard destination != page else { return }
        movesForward = destination.rawValue > page.rawValue
        todoFocused = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            page = destination
        }
        if destination == .firstTodo {
            Task { @MainActor in
                await Task.yield()
                todoFocused = true
            }
        } else {
            shellFocused = true
        }
    }

    private func complete() {
        if store.addTodo(firstTodo) != nil {
            store.saveNow()
        }
        finish()
    }
}

private struct WelcomeOnboardingPage: View {
    var body: some View {
        VStack(spacing: 16) {
            OnboardingHero(
                systemImage: "sparkles.rectangle.stack.fill",
                title: "Your day, remembered.",
                subtitle: "Write what matters. Manas connects it to the work you actually do — and catches what you forgot to list."
            )

            OnboardingIntelligenceDemo()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

private struct SourceSetupOnboardingPage: View {
    @Environment(AppStore.self) private var store
    var probesSources: Bool

    private let sources: [WorkSource] = [.claude, .codex, .arc, .screenTime, .messages]

    private var needsFullDiskAccess: Bool {
        store.sourceStatuses.contains { $0.state == .permissionRequired }
    }

    private var allReady: Bool {
        sources.allSatisfy { status(for: $0).state == .ready }
    }

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHero(
                systemImage: "point.3.connected.trianglepath.dotted",
                title: "Connect the work you already do.",
                subtitle: "Five local signals give every todo real context."
            )

            VStack(spacing: 0) {
                ForEach(sources, id: \.self) { source in
                    OnboardingSourceRow(status: status(for: source))
                    if source != sources.last {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .manasCard(padding: 0)

            sourceAction

            Label {
                Text("Raw databases are never saved by Manas. Compact, same-day evidence is judged through your Claude CLI.")
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Color.manasAccent)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 470)
        }
        .padding(.vertical, 10)
        .task {
            guard probesSources else { return }
            await store.refreshSourceHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard probesSources else { return }
            Task { await store.refreshSourceHealth() }
        }
    }

    @ViewBuilder
    private var sourceAction: some View {
        if allReady {
            Label("All five sources are connected", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
        } else if store.isRefreshingSourceHealth {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking this Mac…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if needsFullDiskAccess {
            VStack(spacing: 7) {
                Button("Open Full Disk Access") {
                    SourceHealthPopover.openFullDiskAccess()
                }
                .buttonStyle(.borderedProminent)
                .tint(.manasAccent)
                .controlSize(.large)

                Text("Turn on Manas, then quit and reopen it. You can finish setup first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("You can continue now and reconnect any unavailable source later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func status(for source: WorkSource) -> ActivitySourceStatus {
        store.sourceStatuses.first { $0.source == source } ?? .waiting(source)
    }
}

private struct FirstTodoOnboardingPage: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var submit: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            OnboardingHero(
                systemImage: "scope",
                title: "What matters today?",
                subtitle: "Give Manas one thing to watch. You can change it anytime."
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.manasAccent)

                    TextField("e.g. Ship the onboarding", text: $text)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.medium))
                        .focused(isFocused)
                        .onSubmit(submit)
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(
                    Color.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isFocused.wrappedValue ? Color.manasAccent : Color.hairline, lineWidth: isFocused.wrappedValue ? 1.5 : 0.5)
                }

                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Optional — you can also start with an empty day."
                    : "This will be added to Today and included in your first check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .frame(maxWidth: 500)

            OnboardingLoopView()
                .frame(maxWidth: 500)

            Text("Manas checks once when you enter the app, then quietly refreshes every hour.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(.vertical, 16)
    }
}

private struct OnboardingHero: View {
    var systemImage: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(Color.manasAccent)
                .frame(width: 58, height: 58)
                .background(Color.manasAccent.opacity(0.11), in: Circle())

            Text(title)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app icon's central mark, rendered in SwiftUI so previews and unbundled
/// development builds carry the same identity as the signed application.
private struct ManasBrandMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.surfaceRaised)
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
            VStack(spacing: size * 0.10) {
                Circle()
                    .fill(Color.manasAccent)
                    .frame(width: size * 0.34, height: size * 0.34)
                Capsule()
                    .fill(Color.manasAccent)
                    .frame(width: size * 0.52, height: max(2, size * 0.07))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct OnboardingSourceRow: View {
    var status: ActivitySourceStatus

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: status.source.systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(status.source.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(status.state == .permissionRequired ? .orange : .secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            statusIcon
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status.state {
        case .syncing:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .permissionRequired:
            Image(systemName: "lock.circle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .unavailable:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .waiting:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private var detail: String {
        if status.state == .permissionRequired { return "Full Disk Access needed" }
        if let detail = status.detail { return detail }
        return switch status.state {
        case .waiting: "Ready to check"
        case .syncing: "Checking this Mac…"
        case .ready:
            status.activityCount == 0
                ? "Connected · quiet today"
                : "Connected · \(status.activityCount) \(status.activityCount == 1 ? "activity" : "activities") today"
        case .permissionRequired: "Full Disk Access needed"
        case .unavailable: "Not installed or unavailable"
        case .failed: "Could not connect"
        }
    }
}

#Preview("Welcome") {
    OnboardingView(probesSources: false, finish: {})
        .environment(AppStore.previewEmpty)
        .frame(width: 560, height: 780)
}

#Preview("Sources") {
    OnboardingView(initialPage: .sources, probesSources: false, finish: {})
        .environment(AppStore.previewJudged)
        .frame(width: 560, height: 780)
}

#Preview("First todo") {
    OnboardingView(initialPage: .firstTodo, probesSources: false, finish: {})
        .environment(AppStore.previewEmpty)
        .frame(width: 560, height: 780)
}
