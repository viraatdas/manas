import AppKit
import ApplicationServices

/// A small state machine kept separate from AppKit so the timing semantics are
/// deterministic and unit-testable.
struct DoubleTapDetector {
    let maximumInterval: TimeInterval
    private(set) var firstTapAt: TimeInterval?

    init(maximumInterval: TimeInterval = 0.45) {
        self.maximumInterval = maximumInterval
    }

    mutating func registerTap(at timestamp: TimeInterval) -> Bool {
        guard let firstTapAt else {
            self.firstTapAt = timestamp
            return false
        }

        let interval = timestamp - firstTapAt
        guard interval >= 0, interval <= maximumInterval else {
            self.firstTapAt = timestamp
            return false
        }

        self.firstTapAt = nil
        return true
    }

    mutating func reset() {
        firstTapAt = nil
    }
}

/// Observes Caps Lock presses both inside Manas and system-wide. A global
/// monitor observes events without modifying them, so normal Caps Lock
/// behavior remains intact.
@MainActor
final class QuickCaptureShortcutController {
    private static let capsLockKeyCode: UInt16 = 57
    private static let permissionPromptKey = "didRequestQuickCaptureAccessibility"

    private var detector = DoubleTapDetector()
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func start() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        requestAccessibilityPermissionOnce()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let keyCode = event.keyCode
            let timestamp = event.timestamp
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, timestamp: timestamp)
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let keyCode = event.keyCode
            let timestamp = event.timestamp
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, timestamp: timestamp)
            }
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        detector.reset()
    }

    private func handle(keyCode: UInt16, timestamp: TimeInterval) {
        guard keyCode == Self.capsLockKeyCode else { return }
        guard detector.registerTap(at: timestamp) else { return }
        presentQuickCapture()
    }

    private func presentQuickCapture() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = AppDelegate.mainWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }

        // The retained window may need one run-loop turn to become key before
        // ScrollViewReader can move Today and focus its NSTextField.
        Task { @MainActor in
            await Task.yield()
            NotificationCenter.default.post(name: .manasJumpToToday, object: nil)
        }
    }

    private func requestAccessibilityPermissionOnce() {
        guard !AXIsProcessTrusted() else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.permissionPromptKey) else { return }
        defaults.set(true, forKey: Self.permissionPromptKey)

        // The exported `kAXTrustedCheckOptionPrompt` is declared as mutable in
        // the C header, which Swift 6 rejects from main-actor code. Its stable
        // documented string value avoids that false-positive.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
