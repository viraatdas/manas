import AppKit
import Combine
import SwiftUI

/// Promotes the process to a regular, activated app so the window reliably
/// comes to the front even when launched via `swift run` (no app bundle).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quickCaptureShortcut = QuickCaptureShortcutController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        quickCaptureShortcut.start()

        // Retain the SwiftUI window after its close button is clicked. Manas
        // remains available for global quick capture until the user explicitly
        // quits the app.
        Task { @MainActor in
            await Task.yield()
            Self.mainWindow?.isReleasedWhenClosed = false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag else { return true }
        Self.mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        quickCaptureShortcut.stop()
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == "main" || $0.title == "Manas"
        }
    }
}

@main
struct ManasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @State private var sync = SyncController()

    var body: some Scene {
        Window("Manas", id: "main") {
            ContentView()
                .environment(store)
                .environment(sync)
                .frame(
                    minWidth: 460,
                    maxWidth: .infinity,
                    minHeight: 620,
                    maxHeight: .infinity
                )
                // Debounced saves can trail the last mutation by up to 500ms;
                // cancel any active CLI work, then flush so nothing is lost.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.stopAutoCheckIns()
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
