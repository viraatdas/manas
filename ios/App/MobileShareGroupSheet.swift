import SwiftUI

/// Which group the share sheet is open on. A value type so the sheet presents
/// from the feed rather than from a row that may scroll away mid-interaction.
struct SharedGroupTarget: Identifiable, Hashable {
    var label: String
    var shareID: UUID?

    var id: String { shareID?.uuidString ?? TodoGroupName.key(for: label) }
}

/// Sharing a group from the phone — which is where the people you want to
/// share with actually live. Pick someone from your contacts and they see this
/// group in their own Manas and can add to it.
struct MobileShareGroupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncController.self) private var sync
    @Environment(\.dismiss) private var dismiss

    let target: SharedGroupTarget

    @State private var phone = ""
    @State private var inviteeName = ""
    @State private var errorText: String?
    @State private var namingMember: SharedGroupMember?
    @State private var draftName = ""

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
        }
        .alert("Name this person", isPresented: Binding(
            get: { namingMember != nil },
            set: { if !$0 { namingMember = nil } }
        )) {
            TextField("Their name", text: $draftName)
                .textContentType(.name)
            Button("Cancel", role: .cancel) { namingMember = nil }
            Button("Save") {
                if let member = namingMember, let shareID = target.shareID {
                    store.setMemberName(draftName, forMemberWithPhone: member.phone, in: shareID)
                }
                namingMember = nil
            }
        } message: {
            Text("Shown on their avatar as initials, to everyone in the group.")
        }
    }

    /// Picking somebody shares with them. There is no second step and nothing
    /// to fill in: their name rides along from the contact card, which is where
    /// it should come from anyway.
    private func adopt(number: String, name: String?) {
        phone = number
        inviteeName = name ?? ""
        invite()
    }

    private var inviteSection: some View {
        Section {
            // Pick a person, done. Nobody knows anyone's number by heart, and
            // typing one in is the fallback for someone not in your contacts.
            Button {
                // Presented through UIKit, not a SwiftUI sheet: the picker is a
                // remote view controller and never calls back from inside one.
                ContactPickerPresenter.shared.present { number, name in
                    adopt(number: number, name: name)
                }
            } label: {
                Label("Share with someone", systemImage: "person.crop.circle.badge.plus")
            }
            .tint(.manasAccent)

            TextField("Or type a number", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .onSubmit(invite)
            if store.canonicalPhone(phone) != nil {
                Button("Share this group", action: invite)
                    .tint(.manasAccent)
            }
        } header: {
            Text("Share this group")
        } footer: {
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            } else {
                Text("Everything in this group becomes visible to them, and they can add to it.")
            }
        }
    }

    private func memberSection(_ share: SharedGroup) -> some View {
        Section {
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
                    // Digits mean nobody has a name yet. Offer the fix where
                    // the problem is visible rather than burying it in a menu.
                    if canName(member, in: share), member.displayName == nil {
                        Button("Name") { beginNaming(member) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .tint(.manasAccent)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if canName(member, in: share) { beginNaming(member) } }
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
        } header: {
            Text("In this group")
        } footer: {
            Text("Tap someone to name them. Their avatar shows initials instead of the last two digits of their number.")
        }
    }

    /// The owner names anyone; everyone else only themselves. That mirrors what
    /// the server allows, so the write never bounces.
    private func canName(_ member: SharedGroupMember, in share: SharedGroup) -> Bool {
        isOwner || PhoneIdentity.matches(member.phone, store.currentPhone)
    }

    private func beginNaming(_ member: SharedGroupMember) {
        namingMember = member
        draftName = member.displayName ?? ""
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
        // Sharing needs this device to know its own number: that is what an
        // invite's missing country code is resolved against.
        guard store.currentPhone != nil else {
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
