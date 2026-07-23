import SwiftUI

/// The feed's top bar: the Manas wordmark with today's date, a quiet sync
/// status line, and an ellipsis menu carrying the signed-in number and sign
/// out (behind a confirmation). It sits above the scrolling feed rather than in
/// a navigation bar so the large title and status read together.
struct MobileFeedHeader: View {
    @Environment(SyncController.self) private var sync
    @State private var confirmingSignOut = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Manas")
                    .font(.largeTitle.weight(.semibold))
                Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                syncStatus
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
            menu
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.manasBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.hairline).frame(height: 0.5)
        }
    }

    /// One line: a spinner while syncing, the error while failed, else the last
    /// successful sync as a relative time. Hidden entirely before a first sync
    /// so the header stays calm.
    @ViewBuilder
    private var syncStatus: some View {
        switch sync.phase {
        case .syncing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .error(let message):
            Label(shorten(message), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.manasAccent)
                .lineLimit(1)
        case .idle, .signedOut:
            if let lastSyncedAt = sync.lastSyncedAt {
                Label(Self.syncedText(lastSyncedAt), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var menu: some View {
        Menu {
            if let phone = sync.phoneNumber {
                Section("Signed in") {
                    Label(phone, systemImage: "phone.fill")
                }
            }
            Button(role: .destructive) {
                confirmingSignOut = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(Color.surfaceRaised, in: Circle())
                .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 0.5))
        }
        .accessibilityLabel("More")
        .confirmationDialog("Sign out of Manas?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Haptics.bump()
                sync.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your todos stay on this device. Sync stops until you sign back in.")
        }
    }

    private func shorten(_ message: String) -> String {
        message.count > 42 ? String(message.prefix(42)) + "…" : message
    }

    /// "Synced just now" under a minute, otherwise a short relative time.
    private static func syncedText(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Synced just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Synced " + formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The floating compose bar, pinned above the keyboard. A text field plus a
/// group chip; submitting adds the todo to today under the picked group, and
/// the group sticks so several todos can be filed in a row. A firm empty state
/// never blocks input — the bar is always ready.
struct MobileAddBar: View {
    @Environment(AppStore.self) private var store
    var day: Date

    @State private var draft = ""
    @State private var selectedGroup: String?
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.manasAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            TextField("What's the plan for today?", text: $draft)
                .font(.body)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(submit)

            groupChip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.manasAccent.opacity(0.8) : Color.hairline,
                              lineWidth: focused ? 1.5 : 0.5)
        )
        .shadow(color: Color.manasAccent.opacity(focused ? 0.16 : 0.06), radius: focused ? 10 : 5, y: 2)
        .animation(.easeOut(duration: 0.15), value: focused)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .alert("New group", isPresented: $showingNewGroup) {
            TextField("Name", text: $newGroupName)
            Button("Cancel", role: .cancel) { newGroupName = "" }
            Button("Create") {
                if let group = store.createGroup(newGroupName) { selectedGroup = group }
                newGroupName = ""
            }
        }
    }

    private var groupChip: some View {
        Menu {
            Button {
                Haptics.tap()
                selectedGroup = nil
            } label: {
                Label("No group", systemImage: selectedGroup == nil ? "checkmark" : "tray")
            }
            ForEach(store.availableTodoGroups, id: \.self) { group in
                Button {
                    Haptics.tap()
                    selectedGroup = group
                } label: {
                    let isCurrent = selectedGroup.map { TodoGroupName.key(for: $0) } == TodoGroupName.key(for: group)
                    Label("\(store.emoji(forGroup: group)) \(group)", systemImage: isCurrent ? "checkmark" : "")
                }
            }
            Divider()
            Button {
                showingNewGroup = true
            } label: {
                Label("New group…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 5) {
                if let selectedGroup {
                    Text(store.emoji(forGroup: selectedGroup))
                    Text(selectedGroup)
                        .lineLimit(1)
                        .frame(maxWidth: 92, alignment: .leading)
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text("Group").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel(selectedGroup.map { "Group: \($0)" } ?? "Choose a group")
    }

    private func submit() {
        guard store.addTodo(draft, on: day, group: selectedGroup) != nil else { return }
        Haptics.tap()
        draft = ""
        focused = true
    }
}
