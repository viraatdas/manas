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
                if let share, !share.members.isEmpty { memberList(share) }
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
                    .disabled(PhoneIdentity.normalized(phone) == nil)
            }
        }
    }

    private func invite() {
        errorText = nil
        guard sync.isSignedIn else {
            errorText = "Sign in with your phone number first."
            return
        }
        guard PhoneIdentity.normalized(phone) != nil else {
            errorText = "That doesn't look like a phone number."
            return
        }
        if PhoneIdentity.matches(phone, store.currentPhone) {
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.memberLabel(member))
                            .font(.subheadline)
                            .lineLimit(1)
                        if member.displayName != nil || member.phone == share.ownerPhone {
                            Text(caption(for: member, in: share))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    // Digits mean nobody has named them yet; offer the fix
                    // exactly where the digits are.
                    if canName(member, in: share), member.displayName == nil {
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

    private func commitName(for member: SharedGroupMember, in share: SharedGroup) {
        store.setMemberName(draftName, forMemberWithPhone: member.phone, in: share.id)
        namingMemberID = nil
        draftName = ""
    }

    private func caption(for member: SharedGroupMember, in share: SharedGroup) -> String {
        let number = PhoneIdentity.display(member.phone)
        return member.phone == share.ownerPhone ? "\(number) · owner" : number
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
