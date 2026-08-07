import XCTest
@testable import Manas

/// A share row this device may not write does not fail alone: PostgREST fails
/// the whole batch, the throw aborts the share sync, and share sync runs before
/// todos are fetched. One unwritable row therefore stops a member receiving any
/// shared todo at all — silently, on every launch.
final class SharePushGuardTests: XCTestCase {
    private let ownerPhone = "13042164370"
    private let memberPhone = "14155550137"
    private let shareID = UUID()

    private func group(owner: String) -> SharedGroupRecord {
        SharedGroupRecord(
            id: shareID, name: "Apt buy list", emoji: nil, ownerID: owner,
            createdAt: Date(), updatedAt: Date(), deleted: false
        )
    }

    private func member(_ phone: String) -> SharedGroupMemberRecord {
        SharedGroupMemberRecord(
            id: UUID(), shareID: shareID, phone: phone, displayName: nil,
            createdAt: Date(), updatedAt: Date(), deleted: false
        )
    }

    /// The exact production failure: a member's client sent back the group row
    /// it had just pulled, the server answered 403, and that member's shared
    /// todos stopped arriving entirely.
    func testAMemberNeverPushesTheGroupRowItCannotWrite() {
        let owned = group(owner: ownerPhone)
        let result = ShareMerge.pushable(
            groups: [owned], members: [], knownGroups: [owned], currentPhone: memberPhone
        )
        XCTAssertTrue(
            result.groups.isEmpty,
            "only the owner may write the group row; pushing it 403s and wedges the member's whole sync"
        )
    }

    func testTheOwnerStillPushesTheirOwnGroup() {
        let owned = group(owner: ownerPhone)
        let result = ShareMerge.pushable(
            groups: [owned], members: [], knownGroups: [owned], currentPhone: ownerPhone
        )
        XCTAssertEqual(result.groups.count, 1)
    }

    /// A member may still write their own membership row — that is how they set
    /// the name they appear under, and how they leave a group.
    func testAMemberPushesOnlyTheirOwnMembership() {
        let owned = group(owner: ownerPhone)
        let mine = member(memberPhone)
        let theirs = member("15555550100")
        let result = ShareMerge.pushable(
            groups: [], members: [mine, theirs], knownGroups: [owned], currentPhone: memberPhone
        )
        XCTAssertEqual(result.members.map(\.phone), [memberPhone])
    }

    /// The owner writes everybody's membership, which is how invites and
    /// removals travel.
    func testTheOwnerPushesEverybodysMembership() {
        let owned = group(owner: ownerPhone)
        let result = ShareMerge.pushable(
            groups: [], members: [member(memberPhone), member("15555550100")],
            knownGroups: [owned], currentPhone: ownerPhone
        )
        XCTAssertEqual(result.members.count, 2)
    }

    /// Signed out, nothing is pushable — nothing should be attempted.
    func testSignedOutPushesNothing() {
        let owned = group(owner: ownerPhone)
        let result = ShareMerge.pushable(
            groups: [owned], members: [member(ownerPhone)],
            knownGroups: [owned], currentPhone: nil
        )
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(result.members.isEmpty)
    }
}

/// Naming a member is what turns a "65" avatar into initials.
@MainActor
final class MemberNamingTests: XCTestCase {
    private func store() -> AppStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manas-naming-\(UUID().uuidString).json")
        return AppStore(fileURL: url, saveDebounce: .zero)
    }

    func testNamingAMemberReplacesTheDigitsWithInitials() {
        let store = store()
        store.currentPhone = "13042164370"
        store.addTodo("Yellow light bulbs", on: Date())
        store.setTodoGroup(store.todos[0].id, to: TodoDestination(group: "Apt buy list", shareID: nil))
        guard let share = store.shareGroup("Apt buy list", withPhone: "+14155550137") else {
            return XCTFail("sharing the group should succeed")
        }

        let before = share.members.first { $0.phone == "14155550137" }
        XCTAssertEqual(MemberBadge.initials(name: before!.displayName, phone: before!.phone), "37",
                       "with no name, the avatar falls back to the last two digits")

        XCTAssertTrue(store.setMemberName("Krithik Rao", forMemberWithPhone: "+1 415 555 0137", in: share.id))

        let after = store.sharedGroup(id: share.id)?.members.first { $0.phone == "14155550137" }
        XCTAssertEqual(after?.displayName, "Krithik Rao")
        XCTAssertEqual(MemberBadge.initials(name: after!.displayName, phone: after!.phone), "KR")
    }

    /// A member may name themselves but not other people — matching the
    /// server's row-level security, so the write never bounces.
    func testAMemberCannotRenameSomebodyElse() {
        let store = store()
        store.currentPhone = "13042164370"
        store.addTodo("Yellow light bulbs", on: Date())
        store.setTodoGroup(store.todos[0].id, to: TodoDestination(group: "Apt buy list", shareID: nil))
        guard let share = store.shareGroup("Apt buy list", withPhone: "+14155550137") else {
            return XCTFail("sharing the group should succeed")
        }

        store.currentPhone = "15555550100" // somebody who isn't the owner
        XCTAssertFalse(store.setMemberName("Nope", forMemberWithPhone: "+14155550137", in: share.id))
    }
}
