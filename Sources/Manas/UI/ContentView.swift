import SwiftUI

/// The day control panel. A fixed header and usage footer bracket one
/// continuous vertical day feed: scroll up into past days, down into future
/// ones, with Today anchored and primary. Checks still run automatically for
/// today.
struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncController.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasCompletedManasOnboarding") private var hasCompletedOnboarding = false
    @State private var isOnboardingPresented = false
    @State private var showingAnalyticsConsent = false
    @State private var analytics = UsageAnalytics.shared

    private let showsOnboardingOnFirstLaunch: Bool
    private let startsAutoCheckIns: Bool

    init(
        showsOnboardingOnFirstLaunch: Bool = true,
        startsAutoCheckIns: Bool = true
    ) {
        self.showsOnboardingOnFirstLaunch = showsOnboardingOnFirstLaunch
        self.startsAutoCheckIns = startsAutoCheckIns
    }

    /// Content stays a comfortable column when the window gets wide.
    static let contentMaxWidth: CGFloat = 760

    var body: some View {
        ZStack {
            dayControlPanel
                .allowsHitTesting(!isOnboardingPresented)
                .accessibilityHidden(isOnboardingPresented)

            if isOnboardingPresented {
                OnboardingView(finish: finishOnboarding)
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.manasBackground)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.22),
            value: isOnboardingPresented
        )
        .task {
            // Roll any unfinished todos from earlier days onto today, so what
            // was left undone yesterday leads today — but only once sync has
            // landed, or a device that has been closed since yesterday rolls
            // forward todos that were finished elsewhere and wins them back.
            await store.carryForwardOverdueTodos(awaiting: sync)
            if showsOnboardingOnFirstLaunch, !hasCompletedOnboarding {
                isOnboardingPresented = true
            } else {
                if startsAutoCheckIns {
                    store.startAutoCheckIns()
                }
                requestAnalyticsConsentIfNeeded()
            }
        }
        // Cloud sync runs whenever a session exists (signed in from the gear
        // popover); signing out simply stops the overlay.
        .task(id: sync.isSignedIn) {
            if sync.isSignedIn {
                sync.start(store: store)
            } else {
                sync.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showManasOnboarding)) { _ in
            isOnboardingPresented = true
        }
        // Midnight (or waking the Mac on a new day) rolls the previous day's
        // unfinished todos forward without needing a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            store.carryForwardOverdueTodos()
        }
        .alert("Help improve Manas?", isPresented: $showingAnalyticsConsent) {
            Button("Not now", role: .cancel) {
                analytics.setEnabled(false)
            }
            Button("Share anonymous usage") {
                analytics.setEnabled(true)
            }
        } message: {
            Text(
                "Manas can send anonymous feature events and success counts. "
                + "It never sends todo text, messages, browsing, phone numbers, "
                + "keystrokes, or screen recordings. You can change this in Settings."
            )
        }
    }

    private var dayControlPanel: some View {
        VStack(spacing: 0) {
            MainHeaderView()
                .padding(.top, 16)
                .padding(.bottom, 12)
                .padding(.horizontal, 24)
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
            Divider()
            DayFeed()
            MainFooterView()
        }
    }

    private func finishOnboarding() {
        hasCompletedOnboarding = true
        isOnboardingPresented = false
        if startsAutoCheckIns {
            store.startAutoCheckIns()
        }
        requestAnalyticsConsentIfNeeded()
    }

    private func requestAnalyticsConsentIfNeeded() {
        guard analytics.shouldRequestConsent else { return }
        Task { @MainActor in
            await Task.yield()
            showingAnalyticsConsent = true
        }
    }
}

#Preview("Empty") {
    ContentView(showsOnboardingOnFirstLaunch: false, startsAutoCheckIns: false)
        .environment(AppStore.previewEmpty)
        .environment(SyncController())
        .frame(width: 520, height: 760)
}

#Preview("Judged") {
    ContentView(showsOnboardingOnFirstLaunch: false, startsAutoCheckIns: false)
        .environment(AppStore.previewJudged)
        .environment(SyncController())
        .frame(width: 520, height: 760)
}

#Preview("Discovered present") {
    ContentView(showsOnboardingOnFirstLaunch: false, startsAutoCheckIns: false)
        .environment(AppStore.previewWithDiscovered)
        .environment(SyncController())
        .frame(width: 520, height: 760)
}

#Preview("Timeline") {
    ContentView(showsOnboardingOnFirstLaunch: false, startsAutoCheckIns: false)
        .environment(AppStore.previewTimeline)
        .environment(SyncController())
        .frame(width: 520, height: 760)
}

#Preview("Wide") {
    ContentView(showsOnboardingOnFirstLaunch: false, startsAutoCheckIns: false)
        .environment(AppStore.previewTimeline)
        .environment(SyncController())
        .frame(width: 900, height: 760)
}
