import AppKit
import SwiftUI

/// Promotes the process to a regular, activated app so the window reliably
/// comes to the front even when launched via `swift run` (no app bundle).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ManasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("Manas", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 380, minHeight: 480)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 420, height: 640)
    }
}
