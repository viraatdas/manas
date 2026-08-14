import SwiftUI

/// iOS entry point. The store persists into the app's container so the widget
/// (via a shared keychain snapshot) renders the same todos, and the sync
/// controller keeps that state converged with the desktop app through the
/// shared backend. Auth uses the same Stytch REST bridge as macOS, with no web
/// views, so either platform can be the first device signed in.
@main
struct ManasIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStore()
    // Naming `StytchSyncAuth()` here used to bypass `SyncController`'s own
    // default, which is the one that honours `MANAS_DISABLE_SYNC` — so the
    // offline verification seams were silently macOS-only and a simulator run
    // always reached the live backend. Letting the default stand picks the
    // same Stytch bridge in every ordinary launch and the signed-out stand-in
    // when the seam is set.
    @State private var sync = SyncController()

    /// Same as the Mac: opt-in, so only a real app makes a sound.
    init() { Sounds.isEnabled = true }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(sync)
                .onAppear {
                    UsageAnalytics.shared.captureAppOpened()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        UsageAnalytics.shared.captureAppOpened()
                        sync.refreshAuthState()
                        sync.refreshInBackground()
                    }
                }
        }
    }
}
