import AppKit
import Combine
import SwiftUI

/// Screen 1 header: the day you are currently looking at, with one quiet
/// caption line (today's date and check-in status) beneath it; a jump-to-today
/// button, source health, refresh, and settings on the right. Days are
/// navigated by scrolling the feed, and the title follows the scroll so the
/// window always says which day is on screen.
struct MainHeaderView: View {
    @Environment(AppStore.self) private var store
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DayLabel.title(for: store.visibleFeedDay))
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: store.visibleFeedDay)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: subtitle)
            }
            Spacer(minLength: 0)
            JumpToTodayButton()
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

    /// One quiet caption line: the date, then check-in status.
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
        return parts.joined(separator: " · ")
    }
}

/// Returns the feed to today from anywhere in the timeline. Always present
/// rather than only when today is off-screen: the floating pill already covers
/// the scrolled-away case, and a control that comes and goes is one you have to
/// go looking for.
private struct JumpToTodayButton: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .manasJumpToToday, object: nil)
        } label: {
            Image(systemName: "calendar.badge.clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverIcon)
        .accessibilityLabel("Jump to today")
        .help("Jump to today (⌘L)")
    }
}

/// The manual re-check control. The header caption communicates the in-progress
/// state, so the icon stays still and simply ignores clicks until the check ends.
private struct RefreshButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            store.checkInNow()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverIcon)
        .disabled(store.isCheckingIn)
        .accessibilityLabel(store.isCheckingIn ? "Checking now" : "Check now")
        .help(store.isCheckingIn ? "Checking your day…" : "Check your day now")
    }
}

/// Compact settings surface behind the gear: iPhone sync and the
/// launch-at-login toggle driven by `LoginItemController` (SMAppService
/// underneath). A first enable that macOS wants approved opens System
/// Settings › Login items; coming back to the app re-reads the outcome.
struct SettingsPopover: View {
    @State private var loginItem: LoginItemController
    @State private var analytics = UsageAnalytics.shared

    init(loginItem: LoginItemController = .standard()) {
        _loginItem = State(initialValue: loginItem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SyncSettingsSection()
            Divider()
            analyticsSection
            Divider()
            launchAtLoginSection
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { loginItem.refresh() }
        // The user approves us in System Settings, then comes back — pick up
        // the new status the moment the app is active again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var analyticsSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share anonymous usage")
                    .font(.subheadline.weight(.medium))
                Text("Sends feature events and success counts. Never todo text, messages, browsing, phone number, or screen recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { analytics.isEnabled },
                set: { analytics.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.manasAccent)
            .labelsHidden()
            .disabled(!analytics.isConfigured)
        }
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                        .font(.subheadline.weight(.medium))
                    Text("Open Manas when you sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.manasAccent)
                .labelsHidden()
                .disabled(!loginItem.isAvailable)
            }
            if let caption = loginItem.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
