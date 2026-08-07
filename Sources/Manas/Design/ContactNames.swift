import Contacts
import Foundation
import Observation
import os

/// Who the *device* thinks a phone number belongs to.
///
/// A shared group only ever knows its members as numbers — that is the whole
/// identity the server has. But the person reading the screen almost always
/// has those numbers in their address book already, under a name, so the
/// avatar next to a todo can say "KR" instead of asking anybody to recognize
/// a run of digits.
///
/// Two rules shape everything here.
///
/// **Contacts never leave the device.** A resolved name is held in memory,
/// drawn, and forgotten. It is never written to the store, never attached to a
/// member record, and never pushed to Supabase — `displayName` is the field
/// people set *about themselves* and the only one that syncs. So the same
/// group can read "KR" on the phone that has Krithik in its contacts and stay
/// unnamed on a phone that doesn't, which is correct: that is what each device
/// actually knows.
///
/// **A todo row must never wait on the address book.** Lookups happen off the
/// main actor, results land in an observable dictionary, and views read that
/// dictionary synchronously — nil until it is filled, which is what the
/// unnamed glyph is for. Nothing blocks first paint, and a number is looked up
/// once per launch rather than once per redraw.
///
/// This file deliberately lives in `Design/` rather than `Models/`: the widget
/// extension compiles all of `Models/` (see ios/project.yml), and the widget
/// has no business linking Contacts.
@MainActor
@Observable
final class ContactNames {
    /// The app-wide resolver. Avatars read it directly rather than taking it
    /// as a parameter through six call sites; tests build their own with a
    /// fake directory.
    static let shared = ContactNames()

    /// Resolved names, keyed by the canonical phone identity — the same digits
    /// a `SharedGroupMember` stores. Only names that were actually found are
    /// in here; a number with no contact is simply absent.
    private(set) var namesByIdentity: [String: String] = [:]

    private let directory: any ContactDirectory
    /// Identities already looked for, found or not. Keeps a redrawing list
    /// from asking the address book about the same number over and over.
    private var looked: Set<String> = []
    private var queued: Set<String> = []
    private var isLookingUp = false
    private var hasAskedForAccess = false

    init(directory: (any ContactDirectory)? = nil) {
        self.directory = directory
            ?? ProbeContactDirectory.fromEnvironment()
            ?? SystemContactDirectory()
    }

    // MARK: - Reading

    /// The address-book name for a member, or nil while none is known — which
    /// covers "not looked up yet", "no contact", and "no permission" alike.
    /// Callers fall through to the next name in the precedence, so all three
    /// degrade to the same quiet result.
    func name(for member: SharedGroupMember) -> String? {
        guard let identity = PhoneIdentity.normalized(member.phone) else { return nil }
        return namesByIdentity[identity]
    }

    /// What to call a member out loud, for a tooltip or a screen reader.
    ///
    /// The signed-in user keeps the store's own wording: being read your own
    /// contact card instead of "You" is worse, not better.
    func label(for member: SharedGroupMember, signedInAs phone: String?, fallback: String) -> String {
        guard !PhoneIdentity.matches(member.phone, phone), let name = name(for: member) else { return fallback }
        return name
    }

    // MARK: - Resolving

    /// Look these members up in the background. Safe to call from a view's
    /// `.task` on every appearance: numbers already looked for are dropped, and
    /// concurrent calls coalesce into one visit to the address book.
    ///
    /// Does nothing at all without permission — and never asks for it. A list
    /// row is the wrong place for a permission sheet.
    func resolve(_ members: [SharedGroupMember]) {
        guard directory.canRead else { return }
        let wanted = Set(members.compactMap { PhoneIdentity.normalized($0.phone) })
            .subtracting(looked)
        guard !wanted.isEmpty else { return }
        looked.formUnion(wanted)
        queued.formUnion(wanted)
        lookUpNextBatch()
    }

    /// Ask for the address book, once, from a screen that is already about
    /// people — sharing a group, or opening an app that has shared groups in
    /// it. Resolves either way, so a grant that already exists takes effect
    /// without a prompt and a refusal costs nothing.
    func requestAccessIfNeeded(for members: [SharedGroupMember]) async {
        guard !members.isEmpty else { return }
        guard !hasAskedForAccess, directory.canAsk else {
            resolve(members)
            return
        }
        hasAskedForAccess = true
        _ = await directory.requestAccess()
        // A fresh grant means the numbers that were skipped for lack of
        // permission are worth another look.
        looked.removeAll()
        resolve(members)
    }

    private func lookUpNextBatch() {
        guard !isLookingUp, !queued.isEmpty else { return }
        isLookingUp = true
        let batch = queued
        queued.removeAll()
        let directory = self.directory
        Task { [weak self] in
            // `names(for:)` is nonisolated, so this leaves the main actor for
            // the duration of the fetch — the point of the whole exercise.
            let found = await directory.names(for: batch)
            guard let self else { return }
            namesByIdentity.merge(found) { _, new in new }
            isLookingUp = false
            lookUpNextBatch()
        }
    }
}

// MARK: - Matching

/// Whether a number written in an address book and a member's stored identity
/// are the same person.
///
/// Both sides go through `PhoneIdentity`, which is what makes this work: a
/// contact saved the way people say it — "(309) 826-4765", no country code —
/// is not the string the server derives from a JWT, and comparing digits would
/// miss it. `PhoneIdentity.canonical(_:signedInAs:)` resolves a missing
/// country code against a number that already has one, and a member's own
/// identity is exactly such a number, so it can stand in as the home number
/// without this file needing to know who is signed in.
enum ContactMatch {
    static func isSamePerson(_ contactNumber: String, as identity: String) -> Bool {
        // Written internationally on both sides, or already identical digits.
        if PhoneIdentity.matches(contactNumber, identity) { return true }
        // The ordinary case: a national number in Contacts, an E.164 identity
        // in the group. Borrow the country code from the identity itself.
        if PhoneIdentity.canonical(contactNumber, signedInAs: identity) == identity { return true }
        // And the mirror image — a member row written bare, from before
        // identities carried their country code, against a contact that does.
        if let contact = PhoneIdentity.normalized(contactNumber) {
            return PhoneIdentity.canonical(identity, signedInAs: contact) == contact
        }
        return false
    }
}

// MARK: - The address book, behind a seam

/// The address book as this app needs it: a permission state and a batch
/// lookup. A protocol so the resolution rules can be tested without a device
/// and driven from a launch seam during verification.
protocol ContactDirectory: Sendable {
    /// Names can be read right now.
    var canRead: Bool { get }
    /// Nobody has been asked yet, so asking would show the system prompt
    /// rather than being a silent no.
    var canAsk: Bool { get }
    func requestAccess() async -> Bool
    /// Names for whichever of these canonical identities the device knows.
    /// Identities with no contact are absent from the result.
    func names(for identities: Set<String>) async -> [String: String]
}

/// `CNContactStore`, the real thing.
struct SystemContactDirectory: ContactDirectory {
    private var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    var canRead: Bool {
        if status == .authorized { return true }
        // iOS 18 lets someone share part of their address book (there is no
        // macOS equivalent — the case is unavailable there). A partial answer
        // is still an answer; whoever is outside the shared set resolves to
        // nothing and falls through to the unnamed glyph.
        #if os(iOS)
        if #available(iOS 18.0, *), status == .limited { return true }
        #endif
        return false
    }

    var canAsk: Bool { status == .notDetermined }

    func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    func names(for identities: Set<String>) async -> [String: String] {
        guard canRead, !identities.isEmpty else { return [:] }
        let store = CNContactStore()
        let keys: [any CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as NSString,
            CNContactOrganizationNameKey as NSString,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        var found: [String: String] = [:]

        // The indexed path first: one small fetch per member, rather than a
        // walk of an address book that may hold thousands of people.
        for identity in identities {
            let predicate = CNContact.predicateForContacts(
                matching: CNPhoneNumber(stringValue: "+\(identity)")
            )
            guard let matches = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else { continue }
            // Every hit is re-checked against our own identity before its name
            // is believed. The predicate's matching rules are Apple's and
            // undocumented, a Contacts predicate in this app has already been
            // silently ignored once, and the failure this guards against —
            // putting one person's initials on another person's todo — is
            // worse than showing no initials at all.
            for contact in matches {
                guard contact.phoneNumbers.contains(where: {
                    ContactMatch.isSamePerson($0.value.stringValue, as: identity)
                }), let name = Self.name(of: contact) else { continue }
                found[identity] = name
                break
            }
        }

        let byPredicate = found.count
        var missing = identities.subtracting(found.keys)
        guard !missing.isEmpty else {
            Self.logger.debug("contacts: \(byPredicate) of \(identities.count) by predicate")
            return found
        }

        // Whatever the predicate did not return, look for by hand. This is the
        // path that survives the predicate being ignored or matching by rules
        // that don't line up with E.164 — it compares nothing but canonical
        // identities, so a number the address book holds in any shape at all
        // still lands on its member.
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        try? store.enumerateContacts(with: request) { contact, stop in
            guard !missing.isEmpty else {
                stop.pointee = true
                return
            }
            guard let name = Self.name(of: contact) else { return }
            for number in contact.phoneNumbers.map(\.value.stringValue) {
                for identity in missing where ContactMatch.isSamePerson(number, as: identity) {
                    found[identity] = name
                    missing.remove(identity)
                }
            }
        }
        let byScan = found.count - byPredicate
        Self.logger.debug(
            "contacts: \(identities.count) asked, \(byPredicate) by predicate, \(byScan) by scan"
        )
        return found
    }

    /// Which path answered. A Contacts predicate has been silently ignored in
    /// this app before (see the picker), and the symptom — names that quietly
    /// don't resolve — looks exactly like an address book that doesn't have
    /// them. One debug line makes the difference visible in a log next time.
    private static let logger = Logger(subsystem: "Manas", category: "ContactNames")

    /// A person's name, or their company when they are filed as one — a
    /// plumber saved as "Ace Plumbing" has initials too.
    private static func name(of contact: CNContact) -> String? {
        let full = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let full, !full.isEmpty { return full }
        let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return organization.isEmpty ? nil : organization
    }
}

/// A fixed address book, from `MANAS_PROBE_CONTACTS`.
///
/// Verification runs need to prove that a resolved name reaches the avatar
/// without either reading the machine's real contacts or putting a system
/// permission dialog on the user's screen mid-check. Deliberately not
/// `#if DEBUG`: the macOS app is verified from a release bundle
/// (`dist/Manas.app`), the same way `MANAS_DISABLE_SYNC` and
/// `MANAS_STATE_FILE` are.
///
///   MANAS_PROBE_CONTACTS="(309) 826-4765=Krithik Rao,+14155550137=Ada Kane"
///   MANAS_PROBE_CONTACTS="denied"
///
/// Numbers are written the way a real address book would hold them and matched
/// through `ContactMatch`, so the seam exercises the canonicalization rather
/// than side-stepping it.
struct ProbeContactDirectory: ContactDirectory {
    /// Number as written → name.
    var entries: [(number: String, name: String)]
    var canRead: Bool
    var canAsk: Bool { false }

    static func fromEnvironment(
        _ value: String? = ProcessInfo.processInfo.environment["MANAS_PROBE_CONTACTS"]
    ) -> ProbeContactDirectory? {
        guard let value, !value.isEmpty else { return nil }
        if value == "denied" { return ProbeContactDirectory(entries: [], canRead: false) }
        let entries = value.split(separator: ",").compactMap { pair -> (String, String)? in
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { return nil }
            return (String(halves[0]), String(halves[1]))
        }
        return ProbeContactDirectory(entries: entries, canRead: true)
    }

    func requestAccess() async -> Bool { canRead }

    func names(for identities: Set<String>) async -> [String: String] {
        guard canRead else { return [:] }
        var found: [String: String] = [:]
        for identity in identities {
            guard let match = entries.first(where: { ContactMatch.isSamePerson($0.number, as: identity) })
            else { continue }
            found[identity] = match.name
        }
        return found
    }
}
