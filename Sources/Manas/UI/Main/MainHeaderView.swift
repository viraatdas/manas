import ServiceManagement
import SwiftUI

/// Screen 1 header: date navigation on the left; refresh and settings on the
/// right; a muted metadata row ("Last checked 2:14 pm · 2 sources synced")
/// underneath. The spinning refresh icon is the only visible sign that a
/// check-in is running.
struct MainHeaderView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedDate: Date
    @State private var showingSettings = false

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                dayButton(systemImage: "chevron.left", byAdding: -1)
                    .accessibilityLabel("Previous day")
                Text(selectedDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.title3.weight(.semibold))
                dayButton(systemImage: "chevron.right", byAdding: 1)
                    .disabled(isToday)
                    .accessibilityLabel("Next day")
                Spacer(minLength: 0)
                RefreshButton()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverIcon)
                .accessibilityLabel("Settings")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    SettingsPopover()
                }
            }
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.default, value: metadata)
        }
    }

    private func dayButton(systemImage: String, byAdding days: Int) -> some View {
        Button {
            if let moved = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
                selectedDate = moved
            }
        } label: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverIcon)
    }

    private var metadata: String {
        var parts: [String] = []
        if store.isCheckingIn {
            parts.append("Checking your day…")
        } else if let lastChecked = store.lastCheckedAt {
            let time = lastChecked.formatted(date: .omitted, time: .shortened).lowercased()
            parts.append("Last checked \(time)")
        } else {
            parts.append("Not checked yet")
        }
        if store.syncedSourceCount > 0 {
            let noun = store.syncedSourceCount == 1 ? "source" : "sources"
            parts.append("\(store.syncedSourceCount) \(noun) synced")
        }
        return parts.joined(separator: " · ")
    }
}

/// The manual re-check control: an arrow.clockwise that spins while a check
/// is running and ignores clicks until it finishes.
private struct RefreshButton: View {
    @Environment(AppStore.self) private var store
    @State private var rotation = 0.0

    var body: some View {
        Button {
            store.checkInNow()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(rotation))
                .frame(width: 24, height: 24)
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
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}

/// Small settings surface behind the gear: the soft daily token budget,
/// bound straight to `AppStore` so it persists, and the launch-at-login
/// toggle backed by `SMAppService`.
struct SettingsPopover: View {
    @Environment(AppStore.self) private var store
    @State private var launchAtLogin = false
    @State private var loginItemCaption: String?

    /// `SMAppService.mainApp` only works from a real .app bundle; under
    /// `swift run` the executable sits in .build/ and registration would fail.
    private var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
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
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.manasAccent)
                    .font(.subheadline)
                    .disabled(!isBundled)
                if let loginItemCaption {
                    Text(loginItemCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 248)
        .onAppear { readLoginItemState() }
        .onChange(of: launchAtLogin) { _, wanted in
            setLaunchAtLogin(wanted)
        }
    }

    private func readLoginItemState() {
        guard isBundled else {
            loginItemCaption = "Available when Manas runs as an installed app."
            return
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginItemCaption = SMAppService.mainApp.status == .requiresApproval
            ? "Approve Manas in System Settings › Login items."
            : nil
    }

    private func setLaunchAtLogin(_ wanted: Bool) {
        guard isBundled, wanted != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemCaption = SMAppService.mainApp.status == .requiresApproval
                ? "Approve Manas in System Settings › Login items."
                : nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemCaption = "Couldn't update the login item. Try again from System Settings."
        }
    }
}

#Preview("Header") {
    MainHeaderView(selectedDate: .constant(Date()))
        .environment(AppStore.previewJudged)
        .padding(24)
        .frame(width: 520)
        .background(Color.manasBackground)
}

#Preview("Settings popover") {
    SettingsPopover()
        .environment(AppStore.previewEmpty)
}
