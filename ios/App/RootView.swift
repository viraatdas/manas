import SwiftUI
#if DEBUG
import Contacts
import ContactsUI
#endif

/// Gate: phone sign-in until a session exists, then the day feed. Sync starts
/// the moment a signed-in root appears and pauses with sign-out.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncController.self) private var sync
    @State private var analytics = UsageAnalytics.shared
    @State private var showingAnalyticsConsent = false

    var body: some View {
        Group {
            if isPreviewSignedIn || sync.isSignedIn {
                MobileDayFeedView()
            } else {
                PhoneSignInView()
            }
        }
        // One warm coral accent everywhere, like the desktop — not iOS blue.
        .tint(Color.manasAccent)
        // The sign-in screen is the brand moment — always the light look;
        // the feed follows the system appearance once signed in.
        // Light-only, matching the desktop: the phone no longer follows the
        // system appearance once signed in.
        .preferredColorScheme(.light)
        .task(id: sync.isSignedIn) {
            // The widget snapshot mirrors the store whether or not sync runs.
            WidgetSnapshotWriter.shared.start(store: store)
            // The preview seam shows the feed without a real session, so it
            // must never start sync (there's nothing to converge with).
            guard !isPreviewSignedIn, sync.isSignedIn else { return }
            // Sync starts first: carrying forward waits for its first pass, so
            // a phone that has been shut since yesterday doesn't roll a todo
            // that was crossed off on the Mac back onto today.
            sync.start(store: store)
            await store.carryForwardOverdueTodos(awaiting: sync)
            requestAnalyticsConsentIfNeeded()
        }
        // Shared groups only know their people as phone numbers, so the app
        // asks the address book who they are — once, and only once there is
        // somebody on screen to name. Keyed on the count because the first
        // group usually arrives with the first sync pass, after this view.
        .task(id: store.sharedGroups.count) {
            await ContactNames.shared.requestAccessIfNeeded(
                for: store.sharedGroups.flatMap(\.members)
            )
        }
        .task {
            // Pick up any session restored from the shared keychain.
            sync.refreshAuthState()
            #if DEBUG
            if isPreviewSignedIn { DemoSeed.seedIfEmpty(store) }
            // Verification seam for the contact picker. It presents through
            // UIKit rather than a SwiftUI sheet, and the failure mode when that
            // is wrong is silent — the picker renders but never calls back, or
            // never appears at all — so it needs to be drivable without taps.
            if ProcessInfo.processInfo.arguments.contains("-manasProbeContactPicker") {
                try? await Task.sleep(for: .seconds(2))
                ContactPickerPresenter.shared.present { number, name in
                    NSLog("[ManasProbe] contact picked: \(number) name=\(name ?? "-")")
                }
                NSLog("[ManasProbe] contact picker presented")
                // Drive a selection without a tap. Presenting proves the picker
                // appears; only this proves the delegate actually delivers one,
                // which is the half that silently did nothing before.
                try? await Task.sleep(for: .seconds(1))
                let person = CNMutableContact()
                person.givenName = "Probe"
                person.familyName = "Person"
                person.phoneNumbers = [CNLabeledValue(
                    label: CNLabelPhoneNumberMobile,
                    value: CNPhoneNumber(stringValue: "+1 415 555 0137")
                )]
                ContactPickerPresenter.shared.contactPicker(
                    CNContactPickerViewController(), didSelect: person as CNContact
                )
            }
            // Verification seam: sign in via the real StytchSyncAuth → edge
            // function path using phone/code from launch arguments.
            if let phone = UserDefaults.standard.string(forKey: "probePhone"),
               let code = UserDefaults.standard.string(forKey: "probeCode"), !sync.isSignedIn {
                try? await Task.sleep(for: .seconds(2))
                do {
                    try await sync.requestCode(phone: phone)
                    try await sync.verifyCode(phone: phone, code: code)
                    NSLog("[ManasProbe] Stytch sign-in OK")
                } catch {
                    NSLog("[ManasProbe] Stytch sign-in FAILED: \(error)")
                }
            }
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
            // Verification seam for sharing by a number typed the way people
            // say it — no country code. `-manasProbeShareWith 4155550137` runs
            // the same store call the Share button makes and logs the identity
            // that will be pushed, so the digits the server has to match can be
            // checked from outside without a tap.
            //
            // Pass the number as bare digits. UserDefaults parses argument
            // values as old-style plists, so "(415) 555-0137" arrives as an
            // *array* and this reads back nil. And put bare flags like
            // `-manasTestSignIn` last: UserDefaults takes the argument after a
            // key as its value, so a flag in front of this one swallows it.
            if let raw = UserDefaults.standard.string(forKey: "manasProbeShareWith") {
                // Wait for this device's own number, not merely for a session:
                // it arrives with the first sync pass, and it is what a typed
                // number's country code is resolved against.
                for _ in 0..<40 where store.currentPhone == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                let label = "Probe share"
                if store.todos.first(where: { $0.group == label }) == nil {
                    store.addTodo("Probe line", group: label)
                }
                let share = store.shareGroup(label, withPhone: raw)
                NSLog("[ManasProbe] typed=\(raw) canonical=\(store.canonicalPhone(raw) ?? "nil") "
                    + "members=\(share?.members.map(\.phone).joined(separator: ",") ?? "nil")")
            }
            #endif
        }
        .alert("Help improve Manas?", isPresented: $showingAnalyticsConsent) {
            Button("Not now", role: .cancel) {
                analytics.setEnabled(false)
            }
            Button("Share anonymous usage") {
                analytics.setEnabled(true)
            }
        } message: {
            Text(
                "Manas can send anonymous feature events and success counts. "
                + "It never sends todo text, messages, browsing, phone numbers, "
                + "keystrokes, or screen recordings. You can turn this off anytime."
            )
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

    private func requestAnalyticsConsentIfNeeded() {
        guard !isPreviewSignedIn, analytics.shouldRequestConsent else { return }
        Task { @MainActor in
            await Task.yield()
            showingAnalyticsConsent = true
        }
    }
}
