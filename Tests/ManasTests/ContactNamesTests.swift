import XCTest
@testable import Manas

/// Matching an address book against a shared group's members.
///
/// The bug this exists to prevent is silent: a contact that fails to match is
/// indistinguishable from a contact that isn't there, and both draw the same
/// unnamed glyph. So the matcher is tested on the shapes a real address book
/// actually holds rather than on the one canonical form the server stores.
final class ContactMatchTests: XCTestCase {
    /// The reported case: (309) 826-4765 in Contacts, +13098264765 in the group.
    func testANationalContactMatchesAnInternationalMember() {
        let identity = "13098264765"
        for written in ["(309) 826-4765", "309-826-4765", "309.826.4765", "3098264765"] {
            XCTAssertTrue(
                ContactMatch.isSamePerson(written, as: identity),
                "\(written) is how people write a number the server stores as \(identity)"
            )
        }
    }

    func testAnInternationalContactMatchesTheSameMember() {
        let identity = "13098264765"
        for written in ["+1 (309) 826-4765", "+13098264765", "0013098264765", "1 309 826 4765"] {
            XCTAssertTrue(ContactMatch.isSamePerson(written, as: identity), written)
        }
    }

    /// A membership row written before identities carried their country code
    /// still finds its contact — the resolution runs both directions.
    func testABareMemberRowMatchesAContactThatCarriesTheCountryCode() {
        XCTAssertTrue(ContactMatch.isSamePerson("+1 (309) 826-4765", as: "3098264765"))
        XCTAssertTrue(ContactMatch.isSamePerson("(309) 826-4765", as: "3098264765"))
    }

    func testNumbersOutsideNorthAmericaMatchToo() {
        XCTAssertTrue(ContactMatch.isSamePerson("+44 20 7183 8750", as: "442071838750"))
        XCTAssertTrue(ContactMatch.isSamePerson("020 7183 8750", as: "442071838750"),
                      "a UK contact keeps its trunk zero; the identity does not")
        XCTAssertTrue(ContactMatch.isSamePerson("98200 98200", as: "919820098200"))
    }

    /// Putting the wrong person's initials on somebody's todo is worse than
    /// showing none, so anything short of a whole number is refused.
    func testPartialAndUnrelatedNumbersDoNotMatch() {
        XCTAssertFalse(ContactMatch.isSamePerson("826-4765", as: "13098264765"),
                       "a local seven-digit number would need '1309' to be a calling code")
        XCTAssertFalse(ContactMatch.isSamePerson("4765", as: "13098264765"))
        XCTAssertFalse(ContactMatch.isSamePerson("(309) 826-4766", as: "13098264765"))
        XCTAssertFalse(ContactMatch.isSamePerson("+44 20 7183 8750", as: "13098264765"))
        XCTAssertFalse(ContactMatch.isSamePerson("", as: "13098264765"))
    }
}

/// The resolver: precedence, caching, and what happens with no permission.
@MainActor
final class ContactNamesTests: XCTestCase {
    private func member(_ phone: String, displayName: String? = nil) -> SharedGroupMember {
        SharedGroupMember(id: UUID(), phone: phone, displayName: displayName, joinedAt: .now)
    }

    /// `resolve` is fire-and-forget by design — the avatar draws before the
    /// address book answers — so tests wait for the answer to land.
    private func waitForName(
        _ names: ContactNames,
        _ member: SharedGroupMember,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> String? {
        for _ in 0..<200 {
            if let name = names.name(for: member) { return name }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return names.name(for: member)
    }

    func testAContactNameReachesTheMemberItBelongsTo() async {
        let directory = FakeContactDirectory(entries: [("(309) 826-4765", "Krithik Rao")])
        let names = ContactNames(directory: directory)
        let krithik = member("13098264765")

        XCTAssertNil(names.name(for: krithik), "nothing is known before the lookup runs")
        names.resolve([krithik])
        let resolved = await waitForName(names, krithik)

        XCTAssertEqual(resolved, "Krithik Rao")
        XCTAssertEqual(MemberBadge.initials(contactName: resolved, displayName: nil), "KR")
    }

    /// The precedence the badge draws, end to end.
    func testTheAddressBookOutranksAGroupDisplayNameAndBothOutrankNothing() async {
        let directory = FakeContactDirectory(entries: [("+13098264765", "Krithik Rao")])
        let names = ContactNames(directory: directory)
        let known = member("13098264765", displayName: "Apartment Guy")
        let named = member("14155550137", displayName: "Ada Kane")
        let stranger = member("16505550188")

        names.resolve([known, named, stranger])
        _ = await waitForName(names, known)

        XCTAssertEqual(
            MemberBadge.initials(contactName: names.name(for: known), displayName: known.displayName),
            "KR", "the contact card wins"
        )
        XCTAssertEqual(
            MemberBadge.initials(contactName: names.name(for: named), displayName: named.displayName),
            "AK", "no contact, so the name set in the group stands"
        )
        XCTAssertNil(
            MemberBadge.initials(contactName: names.name(for: stranger), displayName: stranger.displayName),
            "nobody has named them anywhere — the avatar draws its glyph, not '88'"
        )
    }

    /// The row *label*, not just the avatar.
    ///
    /// These are separate code paths and only the avatar was ever pinned down,
    /// which is exactly how the share panel came to draw "KR" in the circle and
    /// the raw digits in the text beside it — with a "Name" button offering to
    /// fix a name the phone already knew. Reported as "it shows the number, and
    /// I don't want to type the name myself".
    func testTheShareRowReadsAsTheContactsNameWithoutAnybodyTypingIt() async {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json"))
        store.currentPhone = "13042164370"
        let directory = FakeContactDirectory(entries: [("(309) 826-4765", "Krithik Rao")])
        store.contactNames = ContactNames(directory: directory)

        let share = store.shareGroup("Manas", withPhone: "(309) 826-4765")!
        let krithik = try! XCTUnwrap(share.members.first { $0.phone != store.currentPhone })

        XCTAssertEqual(
            store.memberLabel(krithik), PhoneIdentity.display(krithik.phone),
            "before the address book answers the row is honest about knowing nothing"
        )
        XCTAssertFalse(store.hasName(krithik))

        store.contactNames.resolve([krithik])
        _ = await waitForName(store.contactNames, krithik)

        XCTAssertEqual(store.memberLabel(krithik), "Krithik Rao", "no name was typed anywhere")
        XCTAssertTrue(store.hasName(krithik), "so nothing should still be asking to name him")
        XCTAssertNil(krithik.displayName, "and the contact name was not written onto the record")
    }

    /// The address book outranks a name set in the group, and neither outranks
    /// being yourself — the same order the avatar draws.
    func testYourOwnRowStaysYouEvenWhenYouAreInYourOwnAddressBook() async {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json"))
        store.currentPhone = "13042164370"
        let directory = FakeContactDirectory(entries: [
            ("+13042164370", "Viraat Das"),
            ("+15555550100", "Ada Kane"),
        ])
        store.contactNames = ContactNames(directory: directory)

        let share = store.shareGroup("Manas", withPhone: "15555550100", memberName: "Apartment Guy")!
        let me = try! XCTUnwrap(share.members.first { $0.phone == store.currentPhone })
        let them = try! XCTUnwrap(share.members.first { $0.phone != store.currentPhone })

        store.contactNames.resolve([me, them])
        _ = await waitForName(store.contactNames, them)

        XCTAssertEqual(store.memberLabel(me), "You", "your own contact card is not an improvement")
        XCTAssertEqual(store.memberLabel(them), "Ada Kane", "the address book beats the typed name")
    }

    /// Reported as "it's showing multiple numbers".
    ///
    /// When nobody has a name, the row's title falls back to the number — and
    /// both platforms then drew the number *again* underneath it as the
    /// caption. iOS drew it unconditionally, macOS whenever the member owned
    /// the group. The detail line is now derived from the title rather than
    /// guessed alongside it, so it cannot repeat it.
    func testAnUnnamedMemberNeverShowsTheirNumberTwice() async {
        let store = probeStore()
        store.contactNames = ContactNames(directory: FakeContactDirectory(entries: []))
        let share = store.shareGroup("Apartment", withPhone: "15555550100")!
        let stranger = try! XCTUnwrap(share.members.first { $0.phone != store.currentPhone })

        let row = store.presentation(of: stranger, in: share)

        XCTAssertEqual(row.title, PhoneIdentity.display(stranger.phone))
        XCTAssertNil(row.detail, "the number is already the title; a caption would repeat it")
    }

    /// The same row, when somebody else owns the group: the owner tag still has
    /// to survive, because that is the one thing the caption was carrying.
    func testAnUnnamedOwnerKeepsTheOwnerTagWithoutRepeatingTheNumber() async {
        let store = probeStore()
        store.contactNames = ContactNames(directory: FakeContactDirectory(entries: []))
        let share = store.shareGroup("Apartment", withPhone: "15555550100")!
        let me = try! XCTUnwrap(share.members.first { $0.phone == store.currentPhone })
        let other = try! XCTUnwrap(share.members.first { $0.phone != store.currentPhone })

        // The owner is the signed-in user here, so check both shapes: a titled
        // row keeps number + owner, an untitled one keeps owner alone.
        XCTAssertEqual(store.presentation(of: me, in: share).title, "You")
        XCTAssertEqual(
            store.presentation(of: me, in: share).detail,
            "\(PhoneIdentity.display(me.phone)) · owner"
        )
        XCTAssertNil(store.presentation(of: other, in: share).detail)
    }

    /// "I don't know if it's syncing the name." A name out of the address book
    /// is local and a typed one is not, and the row has to say which.
    func testTheRowDistinguishesANameOnlyYouSeeFromOneTheGroupSees() async {
        let store = probeStore()
        let directory = FakeContactDirectory(entries: [("(309) 826-4765", "Krithik Rao")])
        store.contactNames = ContactNames(directory: directory)
        let share = store.shareGroup("Apartment", withPhone: "13098264765")!
        store.addMember(to: share.id, phone: "15555550100", name: "Ada Kane")
        let current = store.sharedGroup(id: share.id)!
        let fromContacts = try! XCTUnwrap(current.members.first { $0.phone == "13098264765" })
        let typed = try! XCTUnwrap(current.members.first { $0.phone == "15555550100" })

        store.contactNames.resolve(current.members)
        _ = await waitForName(store.contactNames, fromContacts)

        XCTAssertEqual(store.presentation(of: fromContacts, in: current).nameSource, .contacts)
        XCTAssertEqual(store.presentation(of: typed, in: current).nameSource, .group)
        XCTAssertEqual(
            store.nameSource(of: try! XCTUnwrap(current.members.first { $0.phone == store.currentPhone })),
            .you
        )
        XCTAssertNil(
            fromContacts.displayName,
            "a contact name must never be written onto the record — that is what makes it local"
        )
    }

    /// Naming yourself from a group's panel used to write one membership row
    /// and leave `myDisplayName` empty, so the name was missing from your other
    /// groups and from Settings. It is your name everywhere or it is nothing.
    func testNamingYourselfCarriesToEveryGroupAndToSettings() {
        let store = probeStore()
        let apartment = store.shareGroup("Apartment", withPhone: "15555550100")!
        let work = store.shareGroup("Work", withPhone: "13098264765")!

        store.setMyDisplayName("Viraat")

        XCTAssertEqual(store.myDisplayName, "Viraat")
        for id in [apartment.id, work.id] {
            let me = store.sharedGroup(id: id)!.members.first { $0.phone == store.currentPhone }
            XCTAssertEqual(me?.displayName, "Viraat", "your name is missing from a group")
        }
    }

    /// A prompt that never got shown must not count as having asked.
    ///
    /// `hasAskedForAccess` used to be set before the request was awaited, so a
    /// prompt the system never displayed — the app was hidden, or had no
    /// window to present from — burned the single ask for the rest of the
    /// process, and the members list went on silently showing digits. Found on
    /// a Mac whose TCC database had no row for the app at all.
    func testAPromptThatNeverAppearedDoesNotCountAsAsking() async {
        let directory = FakeContactDirectory(entries: [("(309) 826-4765", "Krithik Rao")], canRead: false, canAsk: true)
        directory.ignoreRequests = true          // the prompt never appears
        let names = ContactNames(directory: directory)
        let krithik = member("13098264765")

        await names.requestAccessIfNeeded(for: [krithik])
        XCTAssertEqual(directory.requestCount, 1)
        XCTAssertTrue(names.canAskForContacts, "still undecided")

        // Next time there is a window to present from, it must ask again.
        directory.ignoreRequests = false
        await names.requestAccessIfNeeded(for: [krithik])
        XCTAssertEqual(directory.requestCount, 2, "the app gave up after one unshown prompt")
        XCTAssertTrue(names.canReadContacts)
        let resolved = await waitForName(names, krithik)
        XCTAssertEqual(resolved, "Krithik Rao")
    }

    /// What the members list keys its explanation on.
    func testAccessStateIsReadableSoTheListCanExplainItself() async {
        let denied = ContactNames(directory: FakeContactDirectory(entries: [], canRead: false, canAsk: false))
        XCTAssertFalse(denied.canReadContacts)
        XCTAssertFalse(denied.canAskForContacts, "decided already — Settings is the only way back")

        let fresh = ContactNames(directory: FakeContactDirectory(entries: [], canRead: false, canAsk: true))
        XCTAssertFalse(fresh.canReadContacts)
        XCTAssertTrue(fresh.canAskForContacts, "never asked — a prompt is still worth offering")
    }

    private func probeStore() -> AppStore {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json"))
        store.currentPhone = "13042164370"
        return store
    }

    /// A list redraws constantly; the address book must be read once.
    func testTheAddressBookIsReadOncePerNumberNoMatterHowOftenTheRowRedraws() async {
        let directory = FakeContactDirectory(entries: [("(309) 826-4765", "Krithik Rao")])
        let names = ContactNames(directory: directory)
        let krithik = member("13098264765")

        names.resolve([krithik])
        _ = await waitForName(names, krithik)
        for _ in 0..<50 { names.resolve([krithik]) }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(directory.lookupCount, 1, "one visit for fifty redraws")
        XCTAssertEqual(directory.asked, [["13098264765"]])
        XCTAssertEqual(names.name(for: krithik), "Krithik Rao")
    }

    /// A number with no contact behind it is not re-asked either — "not found"
    /// is an answer, and asking again on every scroll is the bug this guards.
    func testANumberWithNoContactIsNotAskedAboutTwice() async {
        let directory = FakeContactDirectory(entries: [])
        let names = ContactNames(directory: directory)
        let stranger = member("16505550188")

        names.resolve([stranger])
        try? await Task.sleep(for: .milliseconds(50))
        names.resolve([stranger])
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(directory.lookupCount, 1)
        XCTAssertNil(names.name(for: stranger))
    }

    /// Denied is not an error state anywhere in the UI: it looks exactly like
    /// an address book that doesn't have them.
    func testNoPermissionDegradesToTheGroupsOwnNamesWithoutAsking() async {
        let directory = FakeContactDirectory(entries: [("(309) 826-4765", "Krithik Rao")], canRead: false)
        let names = ContactNames(directory: directory)
        let krithik = member("13098264765", displayName: "Krithik")

        names.resolve([krithik])
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(directory.lookupCount, 0, "no read is attempted without permission")
        XCTAssertNil(names.name(for: krithik))
        XCTAssertEqual(
            MemberBadge.initials(contactName: names.name(for: krithik), displayName: krithik.displayName),
            "K", "the group's own name still names them"
        )
    }

    /// `resolve` never prompts — only the deliberate people-shaped screens do.
    func testResolvingNeverAsksForPermission() async {
        let directory = FakeContactDirectory(entries: [], canRead: false, canAsk: true)
        let names = ContactNames(directory: directory)

        names.resolve([member("13098264765")])
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(directory.requestCount, 0)
    }

    func testGrantingAccessResolvesTheNumbersThatWereSkipped() async {
        let directory = FakeContactDirectory(
            entries: [("(309) 826-4765", "Krithik Rao")],
            canRead: false,
            canAsk: true
        )
        let names = ContactNames(directory: directory)
        let krithik = member("13098264765")

        names.resolve([krithik])
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(names.name(for: krithik))

        directory.grant()
        await names.requestAccessIfNeeded(for: [krithik])

        XCTAssertEqual(directory.requestCount, 1)
        let resolved = await waitForName(names, krithik)
        XCTAssertEqual(resolved, "Krithik Rao")
    }

    func testAskingHappensAtMostOnce() async {
        let directory = FakeContactDirectory(entries: [], canRead: false, canAsk: true)
        let names = ContactNames(directory: directory)
        let people = [member("13098264765")]

        await names.requestAccessIfNeeded(for: people)
        await names.requestAccessIfNeeded(for: people)
        await names.requestAccessIfNeeded(for: people)

        XCTAssertEqual(directory.requestCount, 1, "a refusal is not re-litigated every launch")
    }

    /// The signed-in user hears "You", not their own contact card.
    func testTheSpokenLabelPrefersTheContactExceptForYourself() async {
        let directory = FakeContactDirectory(entries: [
            ("(309) 826-4765", "Krithik Rao"),
            ("(304) 216-4370", "Me Myself"),
        ])
        let names = ContactNames(directory: directory)
        let krithik = member("13098264765")
        let me = member("13042164370")

        names.resolve([krithik, me])
        _ = await waitForName(names, krithik)

        XCTAssertEqual(
            names.label(for: krithik, signedInAs: "13042164370", fallback: "+1 (309) 826-4765"),
            "Krithik Rao"
        )
        XCTAssertEqual(
            names.label(for: me, signedInAs: "13042164370", fallback: "You"), "You"
        )
    }

    /// The verification seam that drives the launched apps.
    func testTheProbeDirectoryParsesItsLaunchEnvironment() async {
        let directory = ProbeContactDirectory.fromEnvironment(
            "(309) 826-4765=Krithik Rao,+14155550137=Ada Kane"
        )
        let found = await directory?.names(for: ["13098264765", "14155550137", "16505550188"])
        XCTAssertEqual(found?["13098264765"], "Krithik Rao")
        XCTAssertEqual(found?["14155550137"], "Ada Kane")
        XCTAssertNil(found?["16505550188"])

        let denied = ProbeContactDirectory.fromEnvironment("denied")
        XCTAssertEqual(denied?.canRead, false)
        let deniedNames = await denied?.names(for: ["13098264765"])
        XCTAssertEqual(deniedNames, [:])

        XCTAssertNil(ProbeContactDirectory.fromEnvironment(nil), "unset means the real address book")
        XCTAssertNil(ProbeContactDirectory.fromEnvironment(""))
    }
}

/// An address book that counts how often it was read, so "once per number, not
/// once per redraw" is an assertion rather than a hope.
private final class FakeContactDirectory: ContactDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(number: String, name: String)]
    private var readable: Bool
    private var askable: Bool
    private var lookups: [Set<String>] = []
    private var requests = 0
    private var ignoring = false

    init(entries: [(number: String, name: String)], canRead: Bool = true, canAsk: Bool = false) {
        self.entries = entries
        self.readable = canRead
        self.askable = canAsk
    }

    var canRead: Bool { lock.withLock { readable } }
    var canAsk: Bool { lock.withLock { askable } }
    var lookupCount: Int { lock.withLock { lookups.count } }
    var asked: [Set<String>] { lock.withLock { lookups } }
    var requestCount: Int { lock.withLock { requests } }

    func grant() { lock.withLock { readable = true } }

    /// Stands in for a prompt the system never displays — a hidden app, or one
    /// with no window to present from. The status stays undecided.
    var ignoreRequests: Bool {
        get { lock.withLock { ignoring } }
        set { lock.withLock { ignoring = newValue } }
    }

    func requestAccess() async -> Bool {
        lock.withLock {
            requests += 1
            guard !ignoring else { return false }
            askable = false
            readable = true
            return readable
        }
    }

    func names(for identities: Set<String>) async -> [String: String] {
        lock.withLock {
            guard readable else { return [:] }
            lookups.append(identities)
            var found: [String: String] = [:]
            for identity in identities {
                guard let match = entries.first(where: { ContactMatch.isSamePerson($0.number, as: identity) })
                else { continue }
                found[identity] = match.name
            }
            return found
        }
    }
}
