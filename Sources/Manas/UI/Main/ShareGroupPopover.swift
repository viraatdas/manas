import SwiftUI

/// The sharing sheet behind a group header's person button: pick someone from
/// your contacts and they see this group in their own Manas and can add to it.
/// Sharing is per group, never the whole list, so the popover is also where the
/// current members are shown and removed.
struct ShareGroupPopover: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncController.self) private var sync

    /// The group being shared, by label. It may not have a share yet — that is
    /// the ordinary first-invite case.
    var label: String
    var shareID: UUID?
    var close: () -> Void

    @State private var phone = ""
    @State private var inviteeName = ""
    @State private var errorText: String?
    @State private var namingMemberID: UUID?
    @State private var draftName = ""
    @FocusState private var isPhoneFocused: Bool

    private var share: SharedGroup? { shareID.flatMap { store.sharedGroup(id: $0) } }
    private var isOwner: Bool { share.map(store.isOwner(of:)) ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !sync.isSignedIn {
                signedOutNotice
            } else {
                if isOwner { inviteField }
                if let share, !share.members.isEmpty {
                    memberList(share)
                    contactsAccessNotice(share)
                    namingNote
                }
                if let share { footer(share) }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            guard sync.isSignedIn, isOwner else { return }
            DispatchQueue.main.async { isPhoneFocused = true }
        }
        // The one screen that is entirely about which people are in a group is
        // the right place to ask for the address book — never a todo row.
        .task(id: share?.id) {
            await ContactNames.shared.requestAccessIfNeeded(for: share?.members ?? [])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(store.emoji(for: TodoDestination(group: label, shareID: shareID)))
                Text(label)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        guard let share else {
            return "Share this group with a phone number. They'll see it in their Manas and can add to it."
        }
        if !isOwner {
            let owner = share.members.first { $0.phone == share.ownerPhone }
            let name = owner.map(store.memberLabel) ?? PhoneIdentity.display(share.ownerPhone)
            return "Shared with you by \(name)."
        }
        let others = share.members(excluding: store.currentPhone).count
        return others == 1
            ? "Shared with 1 person. Everything in this group is visible to them."
            : "Shared with \(others) people. Everything in this group is visible to them."
    }

    private var signedOutNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "iphone.badge.exclamationmark")
                .font(.caption)
            Text("Sharing works over phone numbers, so it needs the phone sign-in in Settings.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Invite

    private var inviteField: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Pick a person, done. Nobody knows anyone's number by heart, and
            // typing one in is the fallback for someone not in your contacts.
            ContactPickerButton { number, name in
                phone = number
                inviteeName = name ?? ""
                invite()
            }
            HStack(spacing: 6) {
                TextField("Or type a number", text: $phone)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isPhoneFocused)
                    .onSubmit(invite)
                    .accessibilityLabel("Phone number to share with")
                Button("Share", action: invite)
                    .buttonStyle(.borderedProminent)
                    .tint(.manasAccent)
                    .controlSize(.small)
                    .disabled(store.canonicalPhone(phone) == nil)
            }
        }
    }

    private func invite() {
        errorText = nil
        // Both halves matter: sharing needs a session, and it needs this
        // device to know its own number — that is what an invite's missing
        // country code is resolved against.
        guard sync.isSignedIn, store.currentPhone != nil else {
            errorText = "Sign in with your phone number first."
            return
        }
        // The stored identity, not the digits as typed: a number written the
        // way people say it carries no country code, and the account it has to
        // reach is keyed by the international form.
        guard let identity = store.canonicalPhone(phone) else {
            errorText = PhoneIdentity.normalized(phone) == nil
                ? "That doesn't look like a phone number."
                : "Add the country code, like +1, so this reaches their account."
            return
        }
        if PhoneIdentity.matches(identity, store.currentPhone) {
            errorText = "That's your own number."
            return
        }
        let name = inviteeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: SharedGroup?
        if let shareID, let share = store.sharedGroup(id: shareID), store.isOwner(of: share) {
            result = store.addMember(to: shareID, phone: phone, name: name).map { _ in share }
        } else {
            result = store.shareGroup(label, withPhone: phone, memberName: name)
        }
        guard result != nil else {
            errorText = "They're already in this group."
            return
        }
        phone = ""
        inviteeName = ""
        Haptics.bump()
    }

    // MARK: - Members

    private func memberList(_ share: SharedGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            ForEach(share.members) { member in
                HStack(spacing: 8) {
                    MemberAvatar(member: member, size: 22)
                    if namingMemberID == member.id {
                        // Named in place: the avatar sits right there, so the
                        // initials change under the cursor as you type.
                        TextField("Their name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onSubmit { commitName(for: member, in: share) }
                            .accessibilityLabel("Name for \(PhoneIdentity.display(member.phone))")
                        Button("Save") { commitName(for: member, in: share) }
                            .buttonStyle(.ghost)
                            .controlSize(.small)
                    } else {
                    let row = store.presentation(of: member, in: share)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(row.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            // A name only this Mac knows. Without the marker
                            // there is no way to tell it apart from a name the
                            // whole group can see.
                            if row.nameSource == .contacts {
                                Image(systemName: "person.crop.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("From your Contacts — only you see this name")
                                    .accessibilityLabel("from your Contacts, only you see this name")
                            }
                        }
                        if let detail = row.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    // Your own name is the one thing here that everybody else
                    // sees, so it is always editable — and it goes through
                    // `setMyDisplayName`, which carries it to every group
                    // rather than just this one.
                    if PhoneIdentity.matches(member.phone, store.currentPhone) {
                        Button(store.myDisplayName == nil ? "Your name" : "Rename") {
                            draftName = store.myDisplayName ?? ""
                            namingMemberID = member.id
                        }
                        .buttonStyle(.ghost)
                        .controlSize(.small)
                    } else if canName(member, in: share), store.nameSource(of: member) == .none {
                        // Digits mean nobody has named them anywhere; offer the
                        // fix where the digits are. Somebody the address book
                        // already names is not offered it — the row reads as
                        // their name, so the button would ask for work that
                        // visibly looks done.
                        Button("Name") {
                            draftName = ""
                            namingMemberID = member.id
                        }
                        .buttonStyle(.ghost)
                        .controlSize(.small)
                    }
                    if isOwner, member.phone != share.ownerPhone {
                        Button {
                            store.removeMember(member.id, from: share.id)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from this group")
                        .accessibilityLabel("Remove \(store.memberLabel(member))")
                    }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// The owner names anyone; everyone else only themselves — the same rule
    /// the server enforces, so the write never bounces.
    private func canName(_ member: SharedGroupMember, in share: SharedGroup) -> Bool {
        isOwner || PhoneIdentity.matches(member.phone, store.currentPhone)
    }

    /// Naming yourself is a different write from naming somebody else: it is
    /// your name everywhere, not in this one group. Routing it through
    /// `setMemberName` updated a single membership row and left `myDisplayName`
    /// empty, so the name vanished from your other groups and Settings still
    /// showed a blank field — which reads as "it didn't sync".
    private func commitName(for member: SharedGroupMember, in share: SharedGroup) {
        if PhoneIdentity.matches(member.phone, store.currentPhone) {
            store.setMyDisplayName(draftName)
        } else {
            store.setMemberName(draftName, forMemberWithPhone: member.phone, in: share.id)
        }
        namingMemberID = nil
        draftName = ""
    }

    /// Everyone showing as a phone number has two very different causes —
    /// nobody here is in your address book, or Manas was never allowed to read
    /// it — and they look identical on screen. Only one of them is fixable, so
    /// say which one this is and offer the fix.
    @ViewBuilder
    private func contactsAccessNotice(_ share: SharedGroup) -> some View {
        let contacts = ContactNames.shared
        if !contacts.canReadContacts,
           share.members.contains(where: { store.nameSource(of: $0) == .none }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.caption)
                Text("Manas can't read your Contacts, so people here show as numbers.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(contacts.canAskForContacts ? "Allow" : "Open Settings") {
                    if contacts.canAskForContacts {
                        Task { await contacts.requestAccessIfNeeded(for: share.members) }
                    } else {
                        // The choice has already been made, so asking again is
                        // a silent no — System Settings is the only way back.
                        NSWorkspace.shared.open(URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
                        )!)
                    }
                }
                .buttonStyle(.ghost)
                .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// What a name here does and does not reach. Sharing is the one screen
    /// where "only you can see this" is a real distinction, and the members
    /// list above is otherwise silent about it.
    private var namingNote: some View {
        Text("Names from your Contacts stay on this Mac. A name you type here is shared with everyone in the group.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ share: SharedGroup) -> some View {
        Divider()
        HStack {
            if isOwner {
                Button("Stop sharing", role: .destructive) {
                    store.stopSharing(share.id)
                    close()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
                .help("Everyone loses access; the group stays in your list")
            } else {
                Button("Leave group", role: .destructive) {
                    store.leaveSharedGroup(share.id)
                    close()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
                .help("Its todos stay in your list as a private group")
            }
            Spacer()
            Button("Done", action: close)
                .buttonStyle(.ghost)
                .keyboardShortcut(.defaultAction)
        }
    }
}

#Preview("Share a group") {
    ShareGroupPopover(label: "Manas", shareID: nil) {}
        .environment(AppStore.previewJudged)
        .environment(SyncController())
}
