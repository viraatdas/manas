import SwiftUI

// MARK: - Identity color

extension Color {
    /// The one deliberate exception to "coral accent and nothing else": people
    /// need to be told apart, and initials alone don't do it at 20pt. These are
    /// low-saturation mid-tones, drawn as a soft fill with the same hue for the
    /// letters, so a row of avatars reads as quiet metadata and never competes
    /// with an actual action. Coral is not among them — an avatar must not look
    /// like a button.
    static let memberPalette: [Color] = [
        Color(red: 91 / 255, green: 108 / 255, blue: 191 / 255),  // indigo
        Color(red: 46 / 255, green: 139 / 255, blue: 132 / 255),  // teal
        Color(red: 138 / 255, green: 90 / 255, blue: 155 / 255),  // plum
        Color(red: 111 / 255, green: 139 / 255, blue: 63 / 255),  // olive
        Color(red: 78 / 255, green: 110 / 255, blue: 142 / 255),  // slate
        Color(red: 176 / 255, green: 106 / 255, blue: 69 / 255),  // clay
    ]

    /// A person's color, fixed by their number so they look the same on every
    /// device and in every group.
    static func memberTint(forPhone phone: String) -> Color {
        memberPalette[MemberBadge.paletteIndex(for: phone, slots: memberPalette.count)]
    }
}

// MARK: - Avatar

/// The little circle that says who added something: initials on a soft tint,
/// sized to sit inside a todo row without pushing anything around.
///
/// Given a member it names them itself, from this device's address book first
/// (see `ContactNames`) and the group's own display name second. The lookup is
/// asynchronous, so the first paint of a row draws the unnamed glyph and the
/// letters arrive a moment later; the disc is the same size either way, so
/// nothing reflows when they do.
struct MemberAvatar: View {
    /// What the disc draws.
    enum Mark: Equatable, Sendable {
        case text(String)
        /// Somebody this device has no name for — including somebody it hasn't
        /// looked up yet, and somebody it isn't allowed to look up.
        case unnamed
    }

    /// Set when the avatar names a person; nil for the stack's "+3" disc,
    /// which is a count rather than anybody.
    private let member: SharedGroupMember?
    private let fixedMark: Mark
    private let tint: Color
    private let size: CGFloat

    /// A disc with fixed contents — the overflow count, or a preview.
    init(mark: Mark, tint: Color, size: CGFloat = 20) {
        self.member = nil
        self.fixedMark = mark
        self.tint = tint
        self.size = size
    }

    init(initials: String, tint: Color, size: CGFloat = 20) {
        self.init(mark: .text(initials), tint: tint, size: size)
    }

    /// The avatar for one member of a shared group.
    init(member: SharedGroupMember, size: CGFloat = 20) {
        self.member = member
        self.fixedMark = .unnamed
        self.tint = .memberTint(forPhone: member.phone)
        self.size = size
    }

    /// Read inside `body` rather than stored, so the letters appear the moment
    /// the address book answers.
    private var mark: Mark {
        guard let member else { return fixedMark }
        return MemberBadge.initials(
            contactName: ContactNames.shared.name(for: member),
            displayName: member.displayName
        )
        .map(Mark.text) ?? .unnamed
    }

    var body: some View {
        content
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
            // One element whatever it draws. A glyph is not a `Text`, so
            // without this an unnamed avatar had nothing for a caller's
            // "Added by …" label to attach to and dropped out of the
            // accessibility tree altogether — visible only by running it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenMark)
            // Asks the resolver, which drops numbers it has already looked for
            // — so this costs nothing on a redraw and never touches Contacts
            // from inside the row's own render.
            .task(id: member?.phone) {
                guard let member else { return }
                ContactNames.shared.resolve([member])
            }
    }

    @ViewBuilder
    private var content: some View {
        switch mark {
        case .text(let value):
            Text(value)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
        case .unnamed:
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.46, weight: .medium))
        }
    }

    /// What the disc says on its own. Callers that know more — the row that
    /// can say *whose* todo it is — override this with their own label.
    private var spokenMark: String {
        switch mark {
        case .text(let value): value
        case .unnamed: "Unnamed person"
        }
    }
}

/// A shared group's people. Past `maximum` it stops and adds a "+3" disc
/// rather than growing forever.
///
/// Deliberately not the overlapping stack the idiom usually calls for: these
/// badges carry two initials, and at 18pt the disc in front covered half the
/// letters of the one behind it — a row of people you couldn't read.
struct MemberAvatarStack: View {
    var members: [SharedGroupMember]
    var size: CGFloat = 18
    var maximum = 3

    private var shown: [SharedGroupMember] { Array(members.prefix(maximum)) }
    private var overflow: Int { max(0, members.count - shown.count) }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(shown) { member in
                MemberAvatar(member: member, size: size)
            }
            if overflow > 0 {
                MemberAvatar(initials: "+\(overflow)", tint: .secondary, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(members.count == 1 ? "1 person" : "\(members.count) people")
        // Everyone at once: a group header asking for its whole row of people
        // in one go is a single visit to the address book instead of one per
        // disc. The per-avatar request stays as the safety net for an avatar
        // drawn on its own.
        .task(id: members.map(\.phone).joined(separator: ",")) {
            ContactNames.shared.resolve(members)
        }
    }
}

#if os(macOS)
#Preview("Avatars") {
    let members = [
        SharedGroupMember(id: UUID(), phone: "14155550137", displayName: "Priya D", joinedAt: .now),
        SharedGroupMember(id: UUID(), phone: "15555550100", displayName: nil, joinedAt: .now),
        SharedGroupMember(id: UUID(), phone: "442071838750", displayName: "Sam", joinedAt: .now),
        SharedGroupMember(id: UUID(), phone: "919820098200", displayName: "Ana Lee", joinedAt: .now),
    ]
    return VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 10) {
            ForEach(members) { MemberAvatar(member: $0, size: 22) }
        }
        MemberAvatarStack(members: members)
    }
    .padding(28)
    .background(Color.surfaceRaised)
}
#endif
