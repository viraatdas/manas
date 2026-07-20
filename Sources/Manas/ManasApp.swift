import AppKit
import Combine
import SwiftUI

/// Promotes the process to a regular, activated app so the window reliably
/// comes to the front even when launched via `swift run` (no app bundle).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
                .frame(
                    minWidth: 460,
                    maxWidth: .infinity,
                    minHeight: 620,
                    maxHeight: .infinity
                )
                // Debounced saves can trail the last mutation by up to 500ms;
                // flush on quit so nothing is lost.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveNow()
                }
        }
        .defaultSize(width: 560, height: 780)
        .commands {
            CommandMenu("Go") {
                Button("Today") {
                    NotificationCenter.default.post(name: .manasJumpToToday, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Manas") {
                    NotificationCenter.default.post(name: .showManasOnboarding, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command])
            }
        }
    }
}
