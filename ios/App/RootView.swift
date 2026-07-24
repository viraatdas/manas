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
            if ProcessInfo.processInfo.arguments.contains("-manasFirebaseSignIn"), !sync.isSignedIn {
                await runSignInProbe(phone: "+15555550100", code: "123456", disableAppVerification: true)
            }
            // Real-number probe: pass the number via launch arguments
            // (`-manasRealSignIn +1...`) so no phone number lives in source.
            if let phone = UserDefaults.standard.string(forKey: "manasRealSignIn"), !sync.isSignedIn {
                await runSignInProbe(phone: phone, code: nil, disableAppVerification: false)
            }
            #endif
        }
    }

    #if DEBUG
    /// Headless sign-in probe for simulator verification. With a nil code it
    /// requests the SMS, then polls Documents/otp.txt for the code the user
    /// relays from their phone.
    private func runSignInProbe(phone: String, code: String?, disableAppVerification: Bool) async {
        try? await Task.sleep(for: .seconds(2))
        if disableAppVerification {
            FirebaseSyncAuth.setAppVerificationDisabledForTesting(true)
        }
        do {
            try await sync.requestCode(phone: phone)
            NSLog("[ManasProbe] requestCode OK for \(phone)")
        } catch {
            NSLog("[ManasProbe] requestCode FAILED: \(error)")
            return
        }
        var otp = code
        if otp == nil {
            let codeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("otp.txt")
            NSLog("[ManasProbe] awaiting code at \(codeURL.path)")
            for _ in 0..<180 {
                if let read = try? String(contentsOf: codeURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), read.count == 6 {
                    otp = read
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard let otp else { NSLog("[ManasProbe] no code arrived"); return }
        do {
            try await sync.verifyCode(phone: phone, code: otp)
            NSLog("[ManasProbe] verify OK — signed in as \(phone)")
        } catch {
            NSLog("[ManasProbe] verify FAILED: \(error)")
        }
    }
    #endif

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
