import Foundation
import ServiceManagement

/// Seam over `SMAppService.mainApp` so the launch-at-login flow can be
/// unit-tested: the real service only works from an installed .app bundle
/// and mutates per-user system state.
@MainActor
protocol LoginItemManaging {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    /// Takes the user to System Settings › General › Login items.
    func openApprovalSettings()
}

/// The real service — only meaningful when the process runs from a bundle.
struct MainAppLoginItem: LoginItemManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// State machine behind the "Launch at login" toggle.
///
/// The case this exists for: on a first enable macOS may defer to the user —
/// `register()` throws "Operation not permitted" while the status parks on
/// `.requiresApproval`. That is a handshake, not a failure: keep the toggle
/// showing the user's intent, say what is pending, and open System Settings ›
/// Login items so approving is one click. `refresh()` picks up the outcome
/// when the app becomes active again.
@MainActor
@Observable
final class LoginItemController {
    static let approvalCaption = "Approve Manas in System Settings › Login items."
    static let unbundledCaption = "Available when Manas runs as an installed app."
    static let failureCaption = "Couldn't update the login item. Try again from System Settings."

    /// nil under `swift run` (no bundle) — the toggle is disabled then.
    private let item: (any LoginItemManaging)?
    /// True from an enable attempt that needs approval until a refresh sees
    /// the outcome, so the toggle keeps reflecting intent in the meantime.
    private var awaitingApproval = false

    private(set) var isEnabled = false
    private(set) var caption: String?

    var isAvailable: Bool { item != nil }

    init(item: (any LoginItemManaging)?) {
        self.item = item
        // Popovers size themselves from the content's first measurement, so
        // isEnabled/caption must be right from birth — a caption that only
        // arrives with a later refresh() lands in a popover sized without it
        // and gets squeezed.
        refresh()
    }

    /// The production controller: the real service when running from a
    /// bundle, a disabled toggle under `swift run`.
    static func standard() -> LoginItemController {
        let isBundled = Bundle.main.bundleURL.pathExtension == "app"
        return LoginItemController(item: isBundled ? MainAppLoginItem() : nil)
    }

    /// Re-reads the service status — on popover open, and whenever the app
    /// becomes active again (the user may just have approved us in System
    /// Settings). Never opens System Settings itself.
    func refresh() {
        guard let item else {
            isEnabled = false
            caption = Self.unbundledCaption
            return
        }
        switch item.status {
        case .enabled:
            awaitingApproval = false
            isEnabled = true
            caption = nil
        case .requiresApproval:
            // Pending from this session keeps showing the user's intent; an
            // item found already pending on open stays off until approved.
            isEnabled = awaitingApproval
            caption = Self.approvalCaption
        default:
            awaitingApproval = false
            isEnabled = false
            caption = nil
        }
    }

    func setEnabled(_ wanted: Bool) {
        guard let item, wanted != isEnabled else { return }
        if wanted {
            enable(item)
        } else {
            disable(item)
        }
    }

    private func enable(_ item: any LoginItemManaging) {
        awaitingApproval = false
        if item.status != .enabled {
            do {
                try item.register()
            } catch {
                // A first enable that needs the user's blessing throws AND
                // parks the status on .requiresApproval — the approval
                // handshake. Anything else is a real failure.
                guard item.status == .requiresApproval else {
                    isEnabled = item.status == .enabled
                    caption = Self.failureCaption
                    return
                }
            }
        }
        if item.status == .requiresApproval {
            awaitingApproval = true
            isEnabled = true
            caption = Self.approvalCaption
            item.openApprovalSettings()
        } else {
            isEnabled = item.status == .enabled
            caption = isEnabled ? nil : Self.failureCaption
        }
    }

    private func disable(_ item: any LoginItemManaging) {
        awaitingApproval = false
        do {
            try item.unregister()
            isEnabled = item.status == .enabled
            caption = nil
        } catch {
            isEnabled = item.status == .enabled
            caption = Self.failureCaption
        }
    }
}
