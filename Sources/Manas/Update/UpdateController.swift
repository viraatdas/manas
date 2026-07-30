import Foundation
import Observation
import Sparkle

/// Owns the Sparkle updater. Manas ships outside the App Store, so the app
/// keeps itself current: it checks the EdDSA-signed appcast on a daily
/// schedule, then downloads and installs in the background (see
/// `SUAutomaticallyUpdate` in scripts/make-app.sh). A new version is simply
/// there the next time the app relaunches rather than interrupting the day
/// with a prompt.
///
/// Sparkle validates that the downloaded build carries the same Developer ID
/// signature as the running one, which is also what keeps the app's Full Disk
/// Access grant attached across an update.
@MainActor
@Observable
final class UpdateController {
    /// False while a check is already running, so the menu item can disable
    /// itself instead of stacking up requests.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        // `startingUpdater: true` begins the scheduled cadence immediately;
        // the feed URL and public key travel in Info.plist so an unsigned
        // development build (which has neither) simply never finds a feed.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        observation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// The menu's manual check, for when someone would rather not wait for the
    /// scheduled one. Unlike the background pass this one shows its progress.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
