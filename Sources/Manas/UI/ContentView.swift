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
            // Roll any unfinished todos from earlier days onto today before the
            // feed settles, so what was left undone yesterday leads today.
            store.carryForwardOverdueTodos()
            if showsOnboardingOnFirstLaunch, !hasCompletedOnboarding {
                isOnboardingPresented = true
            } else if startsAutoCheckIns {
                store.startAutoCheckIns()
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
