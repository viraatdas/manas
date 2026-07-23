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
            #if DEBUG
            if isPreviewSignedIn { DemoSeed.seedIfEmpty(store) }
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
