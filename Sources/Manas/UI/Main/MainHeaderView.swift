import AppKit
import Combine
import SwiftUI

/// Screen 1 header: the Manas wordmark with one quiet caption line (date,
/// check-in status, sources) on the left; source health, refresh, and settings
/// on the right. Days are navigated by scrolling the feed, so the header no
/// longer pages between dates. The spinning refresh icon is the only visible
/// sign that a check-in is running.
struct MainHeaderView: View {
    @Environment(AppStore.self) private var store
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Manas")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: subtitle)
            }
            Spacer(minLength: 0)
            SourceHealthButton()
            RefreshButton()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverIcon)
            .accessibilityLabel("Settings")
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                SettingsPopover()
            }
        }
    }

    /// One quiet caption line: the date, then check-in status, then sources.
    private var subtitle: String {
        var parts = [Date().formatted(.dateTime.weekday(.wide).month(.wide).day())]
        if store.isCheckingIn {
            parts.append("Checking your day…")
        } else if let lastChecked = store.lastCheckedAt {
            let time = lastChecked.formatted(date: .omitted, time: .shortened).lowercased()
            parts.append("Last checked \(time)")
        } else {
            parts.append("Not checked yet")
        }
        if !store.sourceStatuses.isEmpty {
            parts.append("\(store.syncedSourceCount) of \(store.sourceStatuses.count) sources")
        }
        return parts.joined(separator: " · ")
    }
}

/// The manual re-check control: an arrow.clockwise that spins while a check
/// is running and ignores clicks until it finishes.
private struct RefreshButton: View {
    @Environment(AppStore.self) private var store
    @State private var rotation = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            store.checkInNow()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(rotation))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverIcon)
        .disabled(store.isCheckingIn)
        .accessibilityLabel(store.isCheckingIn ? "Checking now" : "Check now")
        .help(store.isCheckingIn ? "Checking your day…" : "Check your day now")
        .onAppear { if store.isCheckingIn { startSpinning() } }
        .onChange(of: store.isCheckingIn) { _, checking in
            if checking {
                startSpinning()
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { rotation = 0 }
            }
        }
    }

    private func startSpinning() {
        rotation = 0
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}

/// Small settings surface behind the gear: the soft daily token budget,
/// bound straight to `AppStore` so it persists, and the launch-at-login
/// toggle driven by `LoginItemController` (SMAppService underneath). A first
/// enable that macOS wants approved opens System Settings › Login items for
/// the user; coming back to the app re-reads the outcome.
struct SettingsPopover: View {
    @Environment(AppStore.self) private var store
    @State private var loginItem: LoginItemController

    init(loginItem: LoginItemController = .standard()) {
        _loginItem = State(initialValue: loginItem)
    }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Daily token budget")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Daily token budget", value: $store.dailyTokenBudget, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            SyncSettingsSection()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.manasAccent)
                .font(.subheadline)
                .disabled(!loginItem.isAvailable)
                if let caption = loginItem.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 248)
        .onAppear { loginItem.refresh() }
        // The user approves us in System Settings, then comes back — pick up
        // the new status the moment the app is active again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}

#Preview("Header") {
    MainHeaderView()
        .environment(AppStore.previewJudged)
        .environment(SyncController())
        .padding(24)
        .frame(width: 520)
        .background(Color.manasBackground)
}

#Preview("Settings popover") {
    SettingsPopover()
        .environment(AppStore.previewEmpty)
        .environment(SyncController())
}
