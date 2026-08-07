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

    func requestAccess() async -> Bool {
        lock.withLock {
            requests += 1
            askable = false
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
