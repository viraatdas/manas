import SwiftUI

/// iOS entry point. The store persists into the app's container so the widget
/// (via a shared keychain snapshot) renders the same todos, and the sync
/// controller keeps that state converged with the desktop app through the
/// shared backend. Auth is Supabase phone-OTP — a pure REST flow with no web
/// views, so sign-in can never detour through a browser page.
@main
struct ManasIOSApp: App {
    @State private var store = AppStore(fileURL: AppGroup.stateURL)
    @State private var sync = SyncController(stateURL: AppGroup.syncStateURL)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(sync)
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
