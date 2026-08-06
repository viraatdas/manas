import Foundation

/// Phone numbers as identity.
///
/// The server derives a row's owner from the JWT with
/// `regexp_replace(phone, '[^0-9]', '', 'g')`, so the client has to key people
/// by exactly the same digits: a number typed as "+1 (415) 555-0137", one
/// pasted as "001 415 555 0137", and one stored as "14155550137" are one
/// person, and a share addressed to any of them must reach the same account.
enum PhoneIdentity {
    /// The shortest digit count worth treating as a real number, matching the
    /// gate the sign-in field already applies.
    static let minimumDigits = 8

    /// The digits-only identity, or nil when the input isn't a plausible
    /// number. Mirrors the server's `current_phone_id()`.
    static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        var digits = asciiDigits(in: rawValue)
        // "00" is the international access code, the long way of writing "+".
        // It is never part of the identity the server stores.
        if !rawValue.contains("+"), digits.hasPrefix("00") {
            digits = String(digits.dropFirst(2))
        }
        guard digits.count >= minimumDigits else { return nil }
        return digits
    }

    /// Two numbers written any which way, compared as one identity.
    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else { return false }
        return lhs == rhs
    }

    /// Digits back into something a person recognizes. North American numbers
    /// get their familiar grouping; everything else stays a plain `+` number,
    /// because guessing at foreign grouping rules reads worse than not trying.
    static func display(_ digits: String) -> String {
        let digits = asciiDigits(in: digits)
        guard digits.count == 11, digits.hasPrefix("1") else { return "+\(digits)" }
        let rest = digits.dropFirst()
        let area = rest.prefix(3)
        let exchange = rest.dropFirst(3).prefix(3)
        let line = rest.suffix(4)
        return "+1 (\(area)) \(exchange)-\(line)"
    }

    private static func asciiDigits(in value: String) -> String {
        String(value.compactMap { character in
            guard let number = character.wholeNumberValue, (0...9).contains(number) else { return nil }
            return Character(String(number))
        })
    }
}

/// A todo group two or more phone numbers hold in common.
///
/// The owner shares one of their groups with a number; from then on everyone
/// in it sees the same bucket, can add to it, and can check things off. It is
/// deliberately a separate identity from the group *label*: a shared "Manas"
/// and a private "Manas" are two different buckets, so nothing already in your
/// own list is exposed by someone else picking the same name.
struct SharedGroup: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var emoji: String?
    /// Digits of the person who created the share; only they can invite or
    /// remove people, or stop sharing altogether.
    var ownerPhone: String
    /// Everyone in the group, owner first, in join order.
    var members: [SharedGroupMember]
    var createdAt: Date

    func isOwned(by phone: String?) -> Bool {
        PhoneIdentity.matches(ownerPhone, phone)
    }

    func member(withPhone phone: String?) -> SharedGroupMember? {
        guard let phone = PhoneIdentity.normalized(phone) else { return nil }
        return members.first { $0.phone == phone }
    }

    /// Everyone except the given number — the people a "shared with" line names.
    func members(excluding phone: String?) -> [SharedGroupMember] {
        guard let phone = PhoneIdentity.normalized(phone) else { return members }
        return members.filter { $0.phone != phone }
    }
}

/// One person in a shared group. `displayName` is a label anyone in the group
/// can set for themselves (and the owner sets for whoever they invite), so an
/// avatar can read "PD" instead of a phone number.
struct SharedGroupMember: Identifiable, Hashable, Sendable {
    var id: UUID
    var phone: String
    var displayName: String?
    var joinedAt: Date
}

/// How a member is drawn: two initials and a stable slot in the avatar palette.
/// Both are pure functions of the member, so the same person is the same badge
/// on every device and in every group without any shared state.
enum MemberBadge {
    /// Up to two characters. A name gives its initials, a bare number gives its
    /// last two digits — which is what people actually recognize a number by.
    static func initials(name: String?, phone: String) -> String {
        let words = (name ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }
        if !words.isEmpty {
            let letters = words.prefix(2).compactMap { $0.first }
            return String(letters).uppercased()
        }
        let digits = PhoneIdentity.normalized(phone) ?? phone
        return String(digits.suffix(2))
    }

    /// A deterministic palette slot.
    ///
    /// FNV-1a rather than `hashValue`, which Swift seeds per process — an
    /// avatar must not change color when the app relaunches. And rather than
    /// a digit sum, which ignores position: phone numbers within one country
    /// differ by a few digits and kept landing on the same color.
    static func paletteIndex(for phone: String, slots: Int) -> Int {
        guard slots > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in phone.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(hash % UInt64(slots))
    }
}

/// Where a todo lives: a group label, and — when that group is shared — the
/// share it belongs to.
///
/// Grouping is keyed on this rather than on the label alone. Two buckets can
/// legitimately carry the same name (your private "Manas" and the "Manas" a
/// coworker shared with you), and they must never pour into each other: the
/// share id is what keeps a private todo private.
struct TodoDestination: Hashable, Sendable {
    var group: String?
    var shareID: UUID?

    static let ungrouped = TodoDestination(group: nil, shareID: nil)

    init(group: String?, shareID: UUID? = nil) {
        self.group = group
        self.shareID = shareID
    }

    /// Stable identity for `ForEach`, drop targets, and fold keys.
    var key: String {
        if let shareID { return "share:\(shareID.uuidString)" }
        guard let group else { return "__ungrouped__" }
        return TodoGroupName.key(for: group)
    }

    var isShared: Bool { shareID != nil }
}
