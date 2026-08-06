import SwiftUI

/// Which group the share sheet is open on. A value type so the sheet presents
/// from the feed rather than from a row that may scroll away mid-interaction.
struct SharedGroupTarget: Identifiable, Hashable {
    var label: String
    var shareID: UUID?

    var id: String { shareID?.uuidString ?? TodoGroupName.key(for: label) }
}

/// Sharing a group from the phone — which is where the numbers you want to
/// share with actually live. Type a number, and that person sees this group in
/// their own Manas and can add to it.
struct MobileShareGroupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncController.self) private var sync
    @Environment(\.dismiss) private var dismiss

    let target: SharedGroupTarget

    @State private var phone = ""
    @State private var inviteeName = ""
    @State private var myName = ""
    @State private var errorText: String?

    private var share: SharedGroup? { target.shareID.flatMap { store.sharedGroup(id: $0) } }
    private var isOwner: Bool { share.map(store.isOwner(of:)) ?? true }

    var body: some View {
        NavigationStack {
            Form {
                if !sync.isSignedIn {
                    Section {
                        Label(
                            "Sharing works over phone numbers, so it needs the phone sign-in.",
                            systemImage: "iphone.badge.exclamationmark"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } else if isOwner {
                    inviteSection
                }

                if let share, !share.members.isEmpty {
                    memberSection(share)
                }

                if let share {
                    endSection(share)
                }
            }
            .navigationTitle(target.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(.manasAccent)
                }
            }
            .onAppear { myName = store.myDisplayName ?? "" }
        }
    }

    private var inviteSection: some View {
        Section {
            TextField("+1 415 555 0137", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            TextField("Their name (optional)", text: $inviteeName)
                .textContentType(.name)
            Button("Share this group", action: invite)
                .tint(.manasAccent)
                .disabled(PhoneIdentity.normalized(phone) == nil)
            // Avatars are drawn from names, so without one of their own the
            // other side sees a phone number where a person should be.
            TextField("The name you appear as", text: $myName)
                .textContentType(.givenName)
                .onChange(of: myName) { _, name in store.setMyDisplayName(name) }
        } header: {
            Text("Share with a number")
        } footer: {
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            } else {
                Text("Everything in this group becomes visible to them, and they can add to it.")
            }
        }
    }

    private func memberSection(_ share: SharedGroup) -> some View {
        Section("In this group") {
            ForEach(share.members) { member in
                HStack(spacing: 10) {
                    MemberAvatar(member: member, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.memberLabel(member))
                        Text(member.phone == share.ownerPhone
                            ? "\(PhoneIdentity.display(member.phone)) · owner"
                            : PhoneIdentity.display(member.phone))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .swipeActions {
                    if isOwner, member.phone != share.ownerPhone {
                        Button(role: .destructive) {
                            Haptics.bump()
                            store.removeMember(member.id, from: share.id)
                        } label: {
                            Label("Remove", systemImage: "person.badge.minus")
                        }
                    }
                }
            }
        }
    }

    private func endSection(_ share: SharedGroup) -> some View {
        Section {
            if isOwner {
                Button("Stop sharing", role: .destructive) {
                    store.stopSharing(share.id)
                    dismiss()
                }
            } else {
                Button("Leave group", role: .destructive) {
                    store.leaveSharedGroup(share.id)
                    dismiss()
                }
            }
        } footer: {
            Text(isOwner
                ? "Everyone loses access. The group stays in your list with its todos."
                : "Its todos stay in your list as a private group.")
        }
    }

    private func invite() {
        errorText = nil
        guard PhoneIdentity.normalized(phone) != nil else {
            errorText = "That doesn't look like a phone number."
            return
        }
        if PhoneIdentity.matches(phone, store.currentPhone) {
            errorText = "That's your own number."
            return
        }
        store.setMyDisplayName(myName)
        let name = inviteeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let added: Bool
        if let shareID = target.shareID, let share = share, store.isOwner(of: share) {
            added = store.addMember(to: shareID, phone: phone, name: name) != nil
        } else {
            added = store.shareGroup(target.label, withPhone: phone, memberName: name) != nil
        }
        guard added else {
            errorText = "They're already in this group."
            return
        }
        Haptics.bump()
        phone = ""
        inviteeName = ""
    }
}
