import ServiceManagement
import XCTest
@testable import Manas

/// Scriptable stand-in for `SMAppService.mainApp`. `register()` moves the
/// status to `statusAfterRegister` BEFORE throwing, mirroring the real
/// service: a first enable that needs user approval throws "Operation not
/// permitted" while the status parks on `.requiresApproval`.
@MainActor
private final class FakeLoginItem: LoginItemManaging {
    struct StubError: Error {}

    var status: SMAppService.Status = .notRegistered
    var statusAfterRegister: SMAppService.Status = .enabled
    var statusAfterUnregister: SMAppService.Status = .notRegistered
    var registerThrows = false
    var unregisterThrows = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var approvalSettingsOpenCount = 0

    func register() throws {
        registerCount += 1
        status = statusAfterRegister
        if registerThrows { throw StubError() }
    }

    func unregister() throws {
        unregisterCount += 1
        if unregisterThrows { throw StubError() }
        status = statusAfterUnregister
    }

    func openApprovalSettings() {
        approvalSettingsOpenCount += 1
    }
}

@MainActor
final class LoginItemControllerTests: XCTestCase {

    // MARK: - First enable needing approval

    func testFirstEnableNeedingApprovalOpensSystemSettings() {
        // The realistic shape: register() throws AND status parks on
        // .requiresApproval. Not a failure — the approval handshake.
        let item = FakeLoginItem()
        item.statusAfterRegister = .requiresApproval
        item.registerThrows = true
        let controller = LoginItemController(item: item)
        controller.refresh()

        controller.setEnabled(true)

        XCTAssertEqual(item.registerCount, 1)
        XCTAssertEqual(item.approvalSettingsOpenCount, 1, "first enable takes the user to Login items")
        XCTAssertTrue(controller.isEnabled, "the toggle keeps showing the user's intent while approval is pending")
        XCTAssertEqual(controller.caption, LoginItemController.approvalCaption)
    }

    func testFirstEnableNeedingApprovalWithoutThrowAlsoOpensSystemSettings() {
        // Some paths report .requiresApproval without register() throwing.
        let item = FakeLoginItem()
        item.statusAfterRegister = .requiresApproval
        let controller = LoginItemController(item: item)
        controller.refresh()

        controller.setEnabled(true)

        XCTAssertEqual(item.approvalSettingsOpenCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.caption, LoginItemController.approvalCaption)
    }

    func testReturningApprovedClearsTheCaption() {
        let item = FakeLoginItem()
        item.statusAfterRegister = .requiresApproval
        item.registerThrows = true
        let controller = LoginItemController(item: item)
        controller.refresh()
        controller.setEnabled(true)

        item.status = .enabled // the user approved us in System Settings
        controller.refresh()   // app became active again

        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.caption)
        XCTAssertEqual(item.approvalSettingsOpenCount, 1, "refresh never opens System Settings")
    }

    func testReturningStillUnapprovedKeepsIntentAndCaption() {
        let item = FakeLoginItem()
        item.statusAfterRegister = .requiresApproval
        item.registerThrows = true
        let controller = LoginItemController(item: item)
        controller.refresh()
        controller.setEnabled(true)

        controller.refresh() // came back without approving

        XCTAssertTrue(controller.isEnabled, "pending intent from this session stays visible")
        XCTAssertEqual(controller.caption, LoginItemController.approvalCaption)
        XCTAssertEqual(item.approvalSettingsOpenCount, 1)
    }

    func testFreshOpenFindingPendingApprovalShowsOffWithCaption() {
        // A pending item from an earlier session: no intent expressed here,
        // so the toggle reads the actual state (off) with the caption saying why.
        let item = FakeLoginItem()
        item.status = .requiresApproval
        let controller = LoginItemController(item: item)

        controller.refresh()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.caption, LoginItemController.approvalCaption)
        XCTAssertEqual(item.approvalSettingsOpenCount, 0, "only an explicit enable opens System Settings")
    }

    func testEachExplicitEnableReopensSystemSettings() {
        let item = FakeLoginItem()
        item.statusAfterRegister = .requiresApproval
        item.registerThrows = true
        item.statusAfterUnregister = .notRegistered
        let controller = LoginItemController(item: item)
        controller.refresh()

        controller.setEnabled(true)
        controller.setEnabled(false)
        controller.setEnabled(true)

        XCTAssertEqual(item.approvalSettingsOpenCount, 2)
    }

    // MARK: - Plain enable / disable

    func testEnableThatSucceedsOpensNothing() {
        let item = FakeLoginItem()
        item.statusAfterRegister = .enabled
        let controller = LoginItemController(item: item)
        controller.refresh()

        controller.setEnabled(true)

        XCTAssertEqual(item.registerCount, 1)
        XCTAssertEqual(item.approvalSettingsOpenCount, 0)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.caption)
    }

    func testEnableWhenAlreadyEnabledExternallySkipsRegister() {
        let item = FakeLoginItem()
        item.status = .enabled
        let controller = LoginItemController(item: item)

        controller.setEnabled(true)

        XCTAssertEqual(item.registerCount, 0)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.caption)
    }

    func testEnableFailureRevertsToggleWithFailureCaption() {
        let item = FakeLoginItem()
        item.statusAfterRegister = .notRegistered
        item.registerThrows = true
        let controller = LoginItemController(item: item)
        controller.refresh()

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.caption, LoginItemController.failureCaption)
        XCTAssertEqual(item.approvalSettingsOpenCount, 0)
    }

    func testDisableUnregisters() {
        let item = FakeLoginItem()
        item.status = .enabled
        let controller = LoginItemController(item: item)
        controller.refresh()

        controller.setEnabled(false)

        XCTAssertEqual(item.unregisterCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.caption)
    }

    func testDisableWhilePendingApprovalCancelsTheRequest() {
        let item = FakeLoginItem()
        item.statusAfterRegister = .requiresApproval
        item.registerThrows = true
        let controller = LoginItemController(item: item)
        controller.refresh()
        controller.setEnabled(true)

        controller.setEnabled(false)

        XCTAssertEqual(item.unregisterCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.caption)

        // The withdrawn intent must not resurface as "on" from a later refresh.
        item.status = .requiresApproval
        controller.refresh()
        XCTAssertFalse(controller.isEnabled)
    }

    func testDisableFailureRestoresActualState() {
        let item = FakeLoginItem()
        item.status = .enabled
        item.unregisterThrows = true
        let controller = LoginItemController(item: item)
        controller.refresh()

        controller.setEnabled(false)

        XCTAssertTrue(controller.isEnabled, "unregister failed — the item is still enabled")
        XCTAssertEqual(controller.caption, LoginItemController.failureCaption)
    }

    // MARK: - Not bundled (swift run)

    func testUnbundledControllerIsUnavailable() {
        let controller = LoginItemController(item: nil)

        controller.refresh()
        controller.setEnabled(true)

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.caption, LoginItemController.unbundledCaption)
    }
}
