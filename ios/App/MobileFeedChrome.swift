import SwiftUI

/// The feed's top bar: the Manas wordmark with today's date, a quiet sync
/// status line, and an ellipsis menu carrying the signed-in number and sign
/// out (behind a confirmation). It sits above the scrolling feed rather than in
/// a navigation bar so the large title and status read together.
struct MobileFeedHeader: View {
    @Environment(SyncController.self) private var sync
    @State private var analytics = UsageAnalytics.shared
    @State private var confirmingSignOut = false
    @State private var accountAlert: AccountAlert?
    @State private var isDeletingAccount = false
    /// Tapping the wordmark and date jumps the feed back to today. The feed
    /// owns the scroll proxy, so the header just reports the tap upward.
    var onTapToday: () -> Void = {}

    private enum AccountAlert: Identifiable {
        case analyticsConsent
        case confirmDeletion
        case failure(String)

        var id: String {
            switch self {
            case .analyticsConsent: "analytics"
            case .confirmDeletion: "confirm"
            case .failure: "failure"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // The wordmark and date are the way back to today from anywhere in
            // the feed. The sync line sits outside the button: it is a status
            // readout, and swallowing taps on it would make the target feel
            // like it reached further than it looks.
            VStack(alignment: .leading, spacing: 3) {
                Button(action: onTapToday) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Manas")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manas, \(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))")
                .accessibilityHint("Scrolls the feed back to today")
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
            Button {
                if analytics.isEnabled {
                    analytics.setEnabled(false)
                } else {
                    accountAlert = .analyticsConsent
                }
            } label: {
                Label(
                    analytics.isEnabled ? "Stop sharing usage" : "Share anonymous usage…",
                    systemImage: analytics.isEnabled ? "checkmark.circle.fill" : "chart.bar"
                )
            }
            .disabled(!analytics.isConfigured)
            Divider()
            if let phone = sync.phoneNumber {
                Text(phone)
            }
            Button(role: .destructive) {
                confirmingSignOut = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Divider()
            Button(role: .destructive) {
                accountAlert = .confirmDeletion
            } label: {
                Label(
                    isDeletingAccount ? "Deleting account…" : "Delete account…",
                    systemImage: "person.crop.circle.badge.minus"
                )
            }
            .disabled(isDeletingAccount)
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
        .alert(item: $accountAlert) { alert in
            switch alert {
            case .analyticsConsent:
                Alert(
                    title: Text("Share anonymous usage?"),
                    message: Text(
                        "Manas sends feature events and success counts—never todo text, "
                        + "messages, browsing, phone numbers, keystrokes, or screen recordings."
                    ),
                    primaryButton: .default(Text("Share usage")) {
                        analytics.setEnabled(true)
                    },
                    secondaryButton: .cancel()
                )
            case .confirmDeletion:
                Alert(
                    title: Text("Delete your account?"),
                    message: Text(
                        "This permanently deletes your synced todos and account data from Manas, "
                        + "then clears this iPhone. This can’t be undone."
                    ),
                    primaryButton: .destructive(Text("Delete account")) {
                        Task { await deleteAccount() }
                    },
                    secondaryButton: .cancel()
                )
            case .failure(let message):
                Alert(
                    title: Text("Couldn’t delete account"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await sync.deleteAccount()
            Haptics.bump()
        } catch {
            accountAlert = .failure(error.localizedDescription)
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
    @State private var selection: TodoDestination = .ungrouped
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
                if let group = store.createGroup(newGroupName) {
                    selection = TodoDestination(group: group)
                }
                newGroupName = ""
            }
        }
        .task {
            selection = store.suggestedDestinationForNewTodo
        }
        .onChange(of: store.lastManuallyMovedDestination) {
            guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            selection = store.suggestedDestinationForNewTodo
        }
    }

    private var groupChip: some View {
        Menu {
            Button {
                Haptics.tap()
                selection = .ungrouped
            } label: {
                Label("No group", systemImage: selection.group == nil ? "checkmark" : "tray")
            }
            ForEach(store.availableDestinations, id: \.key) { destination in
                Button {
                    Haptics.tap()
                    selection = destination
                } label: {
                    // Shared buckets say so: two entries can carry the same
                    // name, and only one of them is visible to someone else.
                    let name = destination.group ?? ""
                    let title = destination.isShared
                        ? "\(store.emoji(for: destination)) \(name) · shared"
                        : "\(store.emoji(for: destination)) \(name)"
                    Label(title, systemImage: selection.key == destination.key ? "checkmark" : "")
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
                if let label = selection.group {
                    Text(store.emoji(for: selection))
                    Text(label)
                        .lineLimit(1)
                        .frame(maxWidth: 92, alignment: .leading)
                        .foregroundStyle(.primary)
                    if selection.isShared {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
        .accessibilityLabel(selection.group.map { "Group: \($0)" } ?? "Choose a group")
    }

    private func submit() {
        guard store.addTodo(draft, on: day, destination: selection) != nil else { return }
        Haptics.tap()
        draft = ""
        focused = true
    }
}
