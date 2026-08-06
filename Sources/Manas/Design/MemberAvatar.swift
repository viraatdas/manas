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

/// The little circle that says who added something: two initials on a soft
/// tint, sized to sit inside a todo row without pushing anything around.
struct MemberAvatar: View {
    var initials: String
    var tint: Color
    var size: CGFloat = 20

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
    }
}

extension MemberAvatar {
    /// The avatar for one member of a shared group.
    init(member: SharedGroupMember, size: CGFloat = 20) {
        self.init(
            initials: MemberBadge.initials(name: member.displayName, phone: member.phone),
            tint: .memberTint(forPhone: member.phone),
            size: size
        )
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
