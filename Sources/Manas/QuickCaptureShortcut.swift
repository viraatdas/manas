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
    static let permissionPromptKey = "didRequestQuickCaptureAccessibility"
    static let grantedBeforeKey = "quickCaptureAccessibilityGrantedBefore"

    private var detector = DoubleTapDetector()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activationObserver: (any NSObjectProtocol)?
    private var wasTrusted = false

    func start() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        requestAccessibilityPermissionOnce()
        wasTrusted = AXIsProcessTrusted()
        observeTrustBeingGranted()
        startMonitors()
    }

    private func startMonitors() {
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
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        detector.reset()
    }

    /// A global monitor registered while untrusted stays deaf even after the
    /// grant arrives — the registration, not the tap, is what carries the
    /// permission. So granting Accessibility used to require quitting and
    /// reopening Manas before Caps Lock worked. Coming back to the app is the
    /// moment to notice trust appeared and register again.
    private func observeTrustBeingGranted() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                defer { self.wasTrusted = trusted }
                guard trusted, !self.wasTrusted else { return }
                self.restartMonitors()
            }
        }
    }

    private func restartMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        detector.reset()
        startMonitors()
    }

    private func handle(keyCode: UInt16, timestamp: TimeInterval) {
        guard keyCode == Self.capsLockKeyCode else { return }
        guard detector.registerTap(at: timestamp) else { return }
        presentQuickCapture()
    }

    private func presentQuickCapture() {
        UsageAnalytics.shared.capture(.quickCaptureOpened)
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

    /// Re-arms the one-time prompt whenever a grant we used to hold has gone
    /// away. macOS ties an Accessibility grant to the app's code signature, and
    /// a Sparkle update replaces the bundle — so trust is routinely lost across
    /// exactly the updates this app ships. Without this, the first update after
    /// granting killed the shortcut for good: the prompt had already fired
    /// once, so it never fired again, and a global monitor without trust is
    /// silent rather than an error. The symptom is Caps Lock quietly doing
    /// nothing, with nothing in the UI to say why.
    func rearmPromptIfTrustWasLost(_ defaults: UserDefaults, trusted: Bool) {
        if trusted {
            defaults.set(true, forKey: Self.grantedBeforeKey)
        } else if defaults.bool(forKey: Self.grantedBeforeKey) {
            defaults.set(false, forKey: Self.grantedBeforeKey)
            defaults.set(false, forKey: Self.permissionPromptKey)
        }
    }

    private func requestAccessibilityPermissionOnce() {
        let defaults = UserDefaults.standard
        let trusted = AXIsProcessTrusted()
        rearmPromptIfTrustWasLost(defaults, trusted: trusted)
        guard !trusted else { return }

        guard !defaults.bool(forKey: Self.permissionPromptKey) else { return }
        defaults.set(true, forKey: Self.permissionPromptKey)

        // The exported `kAXTrustedCheckOptionPrompt` is declared as mutable in
        // the C header, which Swift 6 rejects from main-actor code. Its stable
        // documented string value avoids that false-positive.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
