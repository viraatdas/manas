import SwiftUI
import FirebaseCore
import FirebaseAuth

/// iOS entry point. The store persists into the app's container so the widget
/// (via a shared keychain snapshot) renders the same todos, and the sync
/// controller — backed by Firebase phone auth here — keeps that state converged
/// with the desktop app through the shared Supabase table.
@main
struct ManasIOSApp: App {
    @UIApplicationDelegateAdaptor(ManasAppDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var sync: SyncController

    init() {
        // FirebaseApp.configure() runs in ManasAppDelegate (the delegate must
        // exist first for phone-auth swizzling); auth state is re-read once
        // the UI appears via SyncController.refreshAuthState().
        _store = State(initialValue: AppStore(fileURL: AppGroup.stateURL))
        _sync = State(initialValue: SyncController(
            auth: FirebaseSyncAuth(),
            stateURL: AppGroup.syncStateURL
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(sync)
                // Completes Firebase's reCAPTCHA fallback for real numbers.
                .onOpenURL { _ = Auth.auth().canHandle($0) }
        }
    }
}

/// Where the app persists its state. The widget gets its data over the shared
/// keychain (WidgetSharedState), not this file, so plain Application Support
/// is all the app needs.
enum AppGroup {
    static var containerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Manas", isDirectory: true)
    }

    static var stateURL: URL { containerURL.appendingPathComponent("state.json") }
    static var syncStateURL: URL { containerURL.appendingPathComponent("sync-state.json") }
}
