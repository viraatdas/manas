import SwiftUI

/// Gate: phone sign-in until a session exists, then the day feed. Sync starts
/// the moment a signed-in root appears and pauses with sign-out.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncController.self) private var sync

    var body: some View {
        Group {
            if isPreviewSignedIn || sync.isSignedIn {
                MobileDayFeedView()
            } else {
                PhoneSignInView()
            }
        }
        // The sign-in screen is the brand moment — always the light look;
        // the feed follows the system appearance once signed in.
        .preferredColorScheme(isPreviewSignedIn || sync.isSignedIn ? nil : .light)
        .task(id: sync.isSignedIn) {
            // The widget snapshot mirrors the store whether or not sync runs.
            WidgetSnapshotWriter.shared.start(store: store)
            // The preview seam shows the feed without a real session, so it
            // must never start sync (there's nothing to converge with).
            guard !isPreviewSignedIn, sync.isSignedIn else { return }
            store.carryForwardOverdueTodos()
            sync.start(store: store)
        }
        .task {
            // Firebase configures in the app delegate, after SyncController
            // was built — pick up a restored session now.
            sync.refreshAuthState()
            #if DEBUG
            if isPreviewSignedIn { DemoSeed.seedIfEmpty(store) }
            // Headless sign-in for simulator verification (no SMS is sent):
            // `-manasTestSignIn` uses the beta test number; a specific account
            // comes via `-manasProbePhone +1... -manasProbeCode 123456` launch
            // arguments so no real number ever lives in source.
            let probePhone = UserDefaults.standard.string(forKey: "manasProbePhone")
                ?? (ProcessInfo.processInfo.arguments.contains("-manasTestSignIn") ? "+15555550100" : nil)
            if let probePhone, !sync.isSignedIn {
                let probeCode = UserDefaults.standard.string(forKey: "manasProbeCode") ?? "123456"
                try? await Task.sleep(for: .seconds(2))
                do {
                    try await sync.requestCode(phone: probePhone)
                    try await sync.verifyCode(phone: probePhone, code: probeCode)
                    NSLog("[ManasProbe] signed in")
                } catch {
                    NSLog("[ManasProbe] sign-in FAILED: \(error)")
                }
            }
            #endif
        }
    }

    /// DEBUG-only screenshot seam: `-manasPreviewSignedIn` skips the sign-in
    /// gate and shows a seeded feed so captures don't need a live session.
    private var isPreviewSignedIn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-manasPreviewSignedIn")
        #else
        false
        #endif
    }
}
