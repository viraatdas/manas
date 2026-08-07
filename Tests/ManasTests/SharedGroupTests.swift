import XCTest
@testable import Manas

/// Identity, badges, and destinations — the pure pieces sharing is built on.
final class SharedGroupIdentityTests: XCTestCase {
    func testEveryWayOfWritingANumberResolvesToOneIdentity() {
        let expected = "14155550137"
        XCTAssertEqual(PhoneIdentity.normalized("+1 (415) 555-0137"), expected)
        XCTAssertEqual(PhoneIdentity.normalized("+14155550137"), expected)
        XCTAssertEqual(PhoneIdentity.normalized("14155550137"), expected)
        XCTAssertEqual(
            PhoneIdentity.normalized("0014155550137"), expected,
            "00 is the long way of writing +, not part of the number"
        )
        XCTAssertTrue(PhoneIdentity.matches("+1 415 555 0137", "14155550137"))
    }

    func testTooFewDigitsIsNotANumber() {
        XCTAssertNil(PhoneIdentity.normalized("555 0137"))
        XCTAssertNil(PhoneIdentity.normalized(""))
        XCTAssertNil(PhoneIdentity.normalized(nil))
        XCTAssertFalse(PhoneIdentity.matches(nil, "14155550137"))
        XCTAssertFalse(
            PhoneIdentity.matches("14155550137", nil),
            "a missing side never matches — signed out is nobody, not everybody"
        )
    }

    /// The bug this rule exists for. "(309) 826-4765" is how a US number is
    /// said out loud, and it was stored as those ten digits — while the
    /// account it names authenticates as eleven, because a JWT phone is E.164.
    /// `is_share_member` compares them with `=`, so the share reached nobody
    /// and RLS correctly hid the whole group from the person it was for.
    func testANumberSaidOutLoudResolvesToTheAccountItNames() {
        let home = "13042164370"
        XCTAssertEqual(PhoneIdentity.canonical("(309) 826-4765", signedInAs: home), "13098264765")
        XCTAssertEqual(PhoneIdentity.canonical("309-826-4765", signedInAs: home), "13098264765")
        XCTAssertEqual(PhoneIdentity.canonical("1 309 826 4765", signedInAs: home), "13098264765")
        XCTAssertEqual(PhoneIdentity.canonical("+1 (309) 826-4765", signedInAs: home), "13098264765")
        XCTAssertEqual(PhoneIdentity.canonical("001 309 826 4765", signedInAs: home), "13098264765")
        XCTAssertEqual(
            PhoneIdentity.canonical("(309) 826-4765", signedInAs: "+1 304 216 4370"),
            PhoneIdentity.canonical("+13098264765", signedInAs: nil),
            "every way of writing it is one identity, with or without a country code"
        )
    }

    /// The country code comes from the inviter's own number, not from a `+1`
    /// nailed into the code: two people in one country write national numbers
    /// of the same length, so the reference carries the answer.
    func testTheCountryCodeComesFromTheInviterNotFromNorthAmerica() {
        XCTAssertEqual(
            PhoneIdentity.canonical("07911 123456", signedInAs: "447700900123"), "447911123456",
            "a UK inviter resolves a UK number, trunk zero and all"
        )
        XCTAssertEqual(
            PhoneIdentity.canonical("98765 43210", signedInAs: "919876500000"), "919876543210"
        )
        XCTAssertEqual(
            PhoneIdentity.canonical("0412 345 678", signedInAs: "61400000000"), "61412345678"
        )
        XCTAssertEqual(
            PhoneIdentity.canonical("447911123456", signedInAs: "13042164370"), "447911123456",
            "a number already longer than the inviter's is already international"
        )
    }

    /// Where the rule cannot tell, it declines rather than storing digits that
    /// reach nobody — the UI turns that into "add the country code".
    func testAnUnresolvableNumberIsRefusedRatherThanGuessedAt() {
        XCTAssertNil(
            PhoneIdentity.canonical("9123 4567", signedInAs: "13042164370"),
            "eight digits under a US inviter would need the prefix '130', which is not a calling code"
        )
        XCTAssertNil(PhoneIdentity.canonical("555 0137", signedInAs: "13042164370"))
        XCTAssertNil(PhoneIdentity.canonical("", signedInAs: "13042164370"))
        XCTAssertNil(PhoneIdentity.canonical(nil, signedInAs: "13042164370"))
        XCTAssertEqual(
            PhoneIdentity.canonical("+65 9123 4567", signedInAs: "13042164370"), "6591234567",
            "spelling out the country code always works"
        )
        XCTAssertEqual(
            PhoneIdentity.canonical("3098264765", signedInAs: nil), "3098264765",
            "signed out there is no country to resolve against; take the digits as given"
        )
    }

    /// The sign-in field on macOS has no country picker beside it, so a number
    /// typed the way people say it takes the device region's code. It used to
    /// take a bare `+`, which sent the OTP provider a different number.
    func testSignInFillsInTheCountryCodeInsteadOfJustAddingAPlus() {
        XCTAssertEqual(PhoneIdentity.e164("(309) 826-4765", defaultDialCode: "1"), "+13098264765")
        XCTAssertEqual(PhoneIdentity.e164("1 309 826 4765", defaultDialCode: "1"), "+13098264765")
        XCTAssertEqual(PhoneIdentity.e164("+44 7911 123456", defaultDialCode: "1"), "+447911123456")
        XCTAssertEqual(PhoneIdentity.e164("0044 7911 123456", defaultDialCode: "1"), "+447911123456")
        XCTAssertEqual(PhoneIdentity.e164("07911 123456", defaultDialCode: "44"), "+447911123456")
        XCTAssertNil(
            PhoneIdentity.e164("309 826 4765", defaultDialCode: nil),
            "an unknown region asks for a + rather than guessing"
        )
        XCTAssertEqual(PhoneIdentity.e164("+3098264765", defaultDialCode: "1"), "+3098264765")
        XCTAssertNil(PhoneIdentity.e164("", defaultDialCode: "1"))
    }

    func testFifteenDigitsIsTheMostANumberCanBe() {
        XCTAssertNotNil(PhoneIdentity.normalized("123456789012345"))
        XCTAssertNil(
            PhoneIdentity.normalized("1234567890123456"),
            "E.164 stops at fifteen; longer is a paste accident"
        )
    }

    func testDisplayGroupsNorthAmericanNumbersAndLeavesOthersPlain() {
        XCTAssertEqual(PhoneIdentity.display("14155550137"), "+1 (415) 555-0137")
        XCTAssertEqual(PhoneIdentity.display("442071838750"), "+442071838750")
    }

    func testInitialsPreferANameAndFallBackToTheLastDigits() {
        XCTAssertEqual(MemberBadge.initials(name: "Priya Das", phone: "14155550137"), "PD")
        XCTAssertEqual(MemberBadge.initials(name: "sam", phone: "14155550137"), "S")
        XCTAssertEqual(MemberBadge.initials(name: nil, phone: "14155550137"), "37")
        XCTAssertEqual(MemberBadge.initials(name: "   ", phone: "14155550137"), "37")
    }

    func testPaletteSlotIsStableAcrossRuns() {
        // Not `hashValue`: Swift seeds that per process, so an avatar would
        // change color every launch.
        let first = MemberBadge.paletteIndex(for: "14155550137", slots: 6)
        XCTAssertEqual(first, MemberBadge.paletteIndex(for: "14155550137", slots: 6))
        XCTAssertTrue((0..<6).contains(first))
        XCTAssertEqual(MemberBadge.paletteIndex(for: "14155550137", slots: 0), 0)
    }

    func testASharedDestinationIsNeverThePrivateOneWithTheSameName() {
        let shareID = UUID()
        let shared = TodoDestination(group: "Manas", shareID: shareID)
        let private_ = TodoDestination(group: "Manas")
        XCTAssertNotEqual(shared.key, private_.key)
        XCTAssertEqual(private_.key, TodoDestination(group: "manas").key, "labels fold case")
        XCTAssertEqual(TodoDestination.ungrouped.key, TodoDestination(group: nil).key)
    }

    func testSectionKeysAreScopedToTheShareAndTheDay() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let shareID = UUID()
        XCTAssertEqual(
            SectionKey.group(TodoDestination(group: "Work"), on: day),
            SectionKey.group("Work", on: day),
            "a private group's fold key is unchanged, so existing folds survive"
        )
        XCTAssertNotEqual(
            SectionKey.group(TodoDestination(group: "Work", shareID: shareID), on: day),
            SectionKey.group("Work", on: day)
        )
    }
}

/// Sharing a group, from the store's point of view.
@MainActor
final class SharedGroupStoreTests: XCTestCase {
    private let mine = "14155550137"
    private let theirs = "15555550100"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private func signedInStore(url: URL? = nil) -> AppStore {
        let store = AppStore(fileURL: url ?? tempStateURL())
        store.currentPhone = mine
        return store
    }

    // MARK: - Creating a share

    func testSharingAGroupAdoptsItsTodosAndSeatsBothPeople() {
        let store = signedInStore()
        store.addTodo("Ship 0.4", group: "Manas")
        store.addTodo("Buy milk", group: "Personal")

        let share = store.shareGroup("Manas", withPhone: "+1 555 555 0100", memberName: "Ada", now: now)

        let unwrapped = try? XCTUnwrap(share)
        XCTAssertEqual(unwrapped?.name, "Manas")
        XCTAssertEqual(unwrapped?.ownerPhone, mine)
        XCTAssertEqual(unwrapped?.members.map(\.phone), [mine, theirs], "the owner leads the list")
        XCTAssertEqual(unwrapped?.members.last?.displayName, "Ada")

        let manas = store.todos.first { $0.text == "Ship 0.4" }
        XCTAssertEqual(manas?.shareID, share?.id, "sharing a group shares what is already in it")
        XCTAssertEqual(manas?.authorPhone, mine)
        XCTAssertNil(
            store.todos.first { $0.text == "Buy milk" }?.shareID,
            "another group is untouched"
        )
    }

    func testSharingRefusesNonsenseAndSelfInvites() {
        let store = signedInStore()
        store.addTodo("Ship 0.4", group: "Manas")
        XCTAssertNil(store.shareGroup("Manas", withPhone: "12345", now: now), "not a number")
        XCTAssertNil(store.shareGroup("Manas", withPhone: "+1 415 555 0137", now: now), "own number")
        XCTAssertTrue(store.sharedGroups.isEmpty)

        let signedOut = AppStore(fileURL: tempStateURL())
        XCTAssertNil(
            signedOut.shareGroup("Manas", withPhone: "+1 555 555 0100", now: now),
            "sharing is keyed on your own number, so it needs a signed-in one"
        )
    }

    /// The regression this whole change exists for, at the level the bug
    /// actually happened: the owner typed a number the way it is said, and the
    /// membership row went in ten digits long while the invitee's account
    /// authenticates as eleven. The server compares them with `=`, so the
    /// group and every todo in it stayed invisible to them — correctly, which
    /// is what made it so hard to see.
    func testAnInviteTypedWithoutACountryCodeStillNamesTheInviteesAccount() {
        let store = signedInStore()
        store.addTodo("2376 W Broadway, Vancouver, BC", group: "Apt buy list")
        let share = store.shareGroup("Apt buy list", withPhone: "(555) 555-0100", now: now)

        XCTAssertEqual(
            share?.members.map(\.phone), [mine, theirs],
            "the roster carries the eleven digits the server derives from their JWT, not the ten typed"
        )
        XCTAssertNotNil(
            share?.member(withPhone: "+1 555 555 0100"),
            "the same person, said out loud or written internationally, is one member"
        )
        XCTAssertEqual(
            store.sharedMemberRecords.map(\.phone).sorted(), [theirs, mine].sorted(),
            "what is pushed to the server is what the server can match"
        )
    }

    /// `currentPhone` arrives with the first sync pass, not at launch. Until
    /// it does there is no country code to resolve against, and resolving
    /// against nothing would write exactly the digits this change exists to
    /// stop — so the invite path is closed rather than approximate.
    func testANationalNumberIsRefusedUntilThisDeviceKnowsItsOwn() {
        let store = AppStore(fileURL: tempStateURL())
        XCTAssertNil(store.canonicalPhone("(555) 555-0100"))
        XCTAssertNil(store.canonicalPhone("+1 555 555 0100"))
        store.currentPhone = mine
        XCTAssertEqual(store.canonicalPhone("(555) 555-0100"), theirs)
    }

    func testInvitingTheSameNumberTwiceIsRejected() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)
        let again = store.shareGroup("Manas", withPhone: "+1 (555) 555-0100", now: now)
        XCTAssertNil(again, "the same person, written differently, is still the same person")
        XCTAssertEqual(store.sharedGroup(id: share!.id)?.members.count, 2)
    }

    // MARK: - Two buckets, one name

    func testAPrivateGroupAndASharedOneWithTheSameNameStaySeparate() {
        let store = signedInStore()
        store.addTodo("Shared thing", group: "Manas")
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        // A later private todo under the same label must not fall into the share.
        store.addTodo("Private thing", destination: TodoDestination(group: "Manas"))

        let groups = store.todoGroups(on: Date())
        let shared = groups.first { $0.shareID == share.id }
        let unshared = groups.first { $0.group == "Manas" && $0.shareID == nil }
        XCTAssertEqual(shared?.todos.map(\.text), ["Shared thing"])
        XCTAssertEqual(unshared?.todos.map(\.text), ["Private thing"])
        XCTAssertNotEqual(shared?.id, unshared?.id, "two buckets, two identities")
    }

    func testTheJudgeNeverFilesATodoIntoASharedGroup() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        let todo = store.addTodo("Unfiled work")!
        store.applyJudgeResult(JudgeResult(
            verdicts: [:],
            groups: [todo.id: "Manas"],
            discovered: [],
            usage: UsageRecord(
                timestamp: now, model: "sonnet", tokensIn: 1, tokensOut: 1,
                costUSD: 0, summary: "test"
            )
        ))
        let judged = store.todos.first { $0.id == todo.id }
        XCTAssertEqual(judged?.group, "Manas")
        XCTAssertNil(
            judged?.shareID,
            "auto-grouping guesses labels; it must never guess private work into someone else's view"
        )
        XCTAssertNotEqual(judged?.destination.key, TodoDestination(group: "Manas", shareID: share.id).key)
    }

    // MARK: - Moving in and out

    func testMovingIntoAndOutOfAShare() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        let todo = store.addTodo("Move me", group: "Work")!

        store.setTodoGroup(todo.id, to: TodoDestination(group: "Manas", shareID: share.id))
        XCTAssertEqual(store.todos.first?.shareID, share.id)
        XCTAssertEqual(store.todos.first?.group, "Manas", "the label follows the share")

        store.setTodoGroup(todo.id, group: "Work")
        XCTAssertNil(store.todos.first?.shareID, "leaving the bucket makes it private again")
        XCTAssertEqual(store.todos.first?.group, "Work")
    }

    func testAddingIntoASharedBucketStampsTheAuthor() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        let todo = store.addTodo("Mine", destination: TodoDestination(group: "Manas", shareID: share.id))
        XCTAssertEqual(todo?.authorPhone, mine)
        XCTAssertEqual(store.author(of: todo!)?.phone, mine)
        XCTAssertEqual(store.memberLabel(store.author(of: todo!)!), "You")
    }

    func testAForeignTodoNamesItsAuthorAndIsKeptOutOfTheJudge() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, memberName: "Ada", now: now)!
        let hers = Todo(
            text: "Her line", group: "Manas", shareID: share.id, authorPhone: theirs
        )
        store.todos.append(hers)

        XCTAssertEqual(store.author(of: hers)?.displayName, "Ada")
        XCTAssertEqual(store.memberLabel(store.author(of: hers)!), "Ada")
        XCTAssertFalse(store.isAuthoredByCurrentUser(hers))
        XCTAssertTrue(
            store.isAuthoredByCurrentUser(Todo(text: "Old", group: "Manas", shareID: share.id)),
            "a todo with no author predates sharing and belongs to whoever is holding it"
        )
    }

    func testDeletingAPrivateGroupLeavesTheSharedOneOfTheSameNameAlone() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        store.addTodo("Shared line", destination: TodoDestination(group: "Manas", shareID: share.id))
        store.createGroup("Manas")
        store.addTodo("Private line", destination: TodoDestination(group: "Manas"))

        store.deleteGroup("Manas")

        let shared = store.todos.first { $0.text == "Shared line" }
        XCTAssertEqual(shared?.group, "Manas", "a shared bucket only ends when its owner stops sharing")
        XCTAssertEqual(shared?.shareID, share.id)
        XCTAssertNil(store.todos.first { $0.text == "Private line" }?.group)
    }

    func testTheirLineCannotBeRefiledOutOfTheGroup() {
        // The server rejects the write (its policies were checked against a
        // real Postgres), and one rejected row fails the whole sync batch —
        // so the store refuses the move rather than queueing a doomed push.
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        let hers = Todo(text: "Her line", group: "Manas", shareID: share.id, authorPhone: theirs)
        store.todos.append(hers)

        store.setTodoGroup(hers.id, group: "Work")
        XCTAssertEqual(store.todos.last?.shareID, share.id)
        XCTAssertEqual(store.todos.last?.group, "Manas")

        // Ticking it off and deleting it are still fine — that is the point of
        // a shared list.
        store.toggleDone(hers.id)
        XCTAssertEqual(store.todos.last?.isDone, true)
        store.removeTodo(hers.id)
        XCTAssertTrue(store.todos.isEmpty)
    }

    // MARK: - Ending a share

    func testStoppingASharingKeepsYourWorkAndDropsTheirs() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        store.addTodo("Mine", destination: TodoDestination(group: "Manas", shareID: share.id))
        store.todos.append(Todo(text: "Theirs", group: "Manas", shareID: share.id, authorPhone: theirs))

        store.stopSharing(share.id, now: now.addingTimeInterval(60))

        XCTAssertTrue(store.sharedGroups.isEmpty)
        XCTAssertEqual(store.todos.map(\.text), ["Mine"])
        XCTAssertNil(store.todos.first?.shareID)
        XCTAssertEqual(store.todos.first?.group, "Manas", "it stays where it was, just privately")
        XCTAssertFalse(
            store.sharedGroupRecords.isEmpty,
            "the tombstone has to survive locally until a sync can push it"
        )
        XCTAssertTrue(store.sharedGroupRecords.allSatisfy(\.deleted))
    }

    func testOnlyTheOwnerInvitesRemovesAndRevokes() {
        let store = signedInStore()
        // A share owned by somebody else, as it arrives from a sync.
        let shareID = UUID()
        store.sharedGroupRecords = [SharedGroupRecord(
            id: shareID, name: "Their list", emoji: "🚀", ownerID: theirs,
            createdAt: now, updatedAt: now, deleted: false
        )]
        let myMembership = UUID()
        store.sharedMemberRecords = [
            SharedGroupMemberRecord(
                id: UUID(), shareID: shareID, phone: theirs, displayName: "Ada",
                createdAt: now, updatedAt: now, deleted: false
            ),
            SharedGroupMemberRecord(
                id: myMembership, shareID: shareID, phone: mine, displayName: nil,
                createdAt: now, updatedAt: now, deleted: false
            ),
        ]
        let share = try? XCTUnwrap(store.sharedGroup(id: shareID))
        XCTAssertFalse(store.isOwner(of: share!))

        store.addMember(to: shareID, phone: "16505550111", now: now)
        XCTAssertEqual(store.sharedGroup(id: shareID)?.members.count, 2, "a guest can't invite")
        store.removeMember(store.sharedGroup(id: shareID)!.members[0].id, from: shareID, now: now)
        XCTAssertEqual(store.sharedGroup(id: shareID)?.members.count, 2, "a guest can't remove")
        store.stopSharing(shareID, now: now)
        XCTAssertNotNil(store.sharedGroup(id: shareID), "a guest can't revoke")

        store.leaveSharedGroup(shareID, now: now)
        XCTAssertNil(store.sharedGroup(id: shareID), "but a guest can leave")
    }

    func testASharePulledAwayReleasesWhatItLeavesBehind() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        store.addTodo("Mine", destination: TodoDestination(group: "Manas", shareID: share.id))
        store.todos.append(Todo(text: "Theirs", group: "Manas", shareID: share.id, authorPhone: theirs))

        // The owner revoked it on their device: the rows simply stop coming.
        store.applyShareMerge(groups: [], members: [])

        XCTAssertTrue(store.sharedGroups.isEmpty)
        XCTAssertEqual(store.todos.map(\.text), ["Mine"])
        XCTAssertNil(
            store.todos.first?.shareID,
            "the server would reject writes to a share we've left, so nothing may still point at it"
        )
    }

    // MARK: - Names, buckets, persistence

    func testYourNameTravelsOntoYourMembershipRows() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        store.setMyDisplayName("  Viraat  ", now: now)
        XCTAssertEqual(store.myDisplayName, "Viraat")
        XCTAssertEqual(store.sharedGroup(id: share.id)?.members.first?.displayName, "Viraat")
        XCTAssertEqual(store.memberLabel(store.sharedGroup(id: share.id)!.members[0]), "Viraat (you)")
    }

    func testASharedGroupStandsAsABucketBeforeAnythingIsInIt() {
        let store = signedInStore()
        let share = store.shareGroup("Manas", withPhone: theirs, now: now)!
        let destinations = store.standingDestinations
        XCTAssertTrue(destinations.contains(TodoDestination(group: "Manas", shareID: share.id)))
        XCTAssertTrue(
            store.availableDestinations.contains(TodoDestination(group: "Manas", shareID: share.id))
        )
        XCTAssertEqual(store.emoji(for: TodoDestination(group: "Manas", shareID: share.id)), "📁")
    }

    func testSharesSurviveRelaunch() {
        let url = tempStateURL()
        let store = signedInStore(url: url)
        store.addTodo("Ship 0.4", group: "Manas")
        let share = store.shareGroup("Manas", withPhone: theirs, memberName: "Ada", now: now)!
        store.saveNow()

        let reloaded = AppStore(fileURL: url)
        reloaded.currentPhone = mine
        XCTAssertEqual(reloaded.sharedGroups.map(\.id), [share.id])
        XCTAssertEqual(reloaded.sharedGroup(id: share.id)?.members.map(\.phone), [mine, theirs])
        XCTAssertEqual(reloaded.todos.first?.shareID, share.id)
        XCTAssertEqual(reloaded.todos.first?.authorPhone, mine)
    }
}
