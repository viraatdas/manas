import SwiftUI

/// One todo row, touch-first. The whole visual vocabulary is shared across the
/// three modes — today (live), history (frozen past), and planned (future) —
/// and only behavior changes: a tappable checkbox with a springy checkmark,
/// the text (struck through when done), an optional verdict line, and the
/// row's interactions. Swipe leading to complete, swipe trailing to delete,
/// long-press for the full action menu. Destructive and completing actions
/// land a firm `bump`; lighter selections land a `tap`.
struct MobileTodoRow: View {
    enum Mode { case today, history, planned }

    @Environment(AppStore.self) private var store
    let todo: Todo
    var mode: Mode = .today
    /// Hoisted to the feed so the reschedule sheet presents from a stable
    /// owner rather than from inside a row that may scroll away. Editing does
    /// not need this: it happens in the row itself, presenting nothing.
    var onReschedule: (Todo) -> Void

    @State private var checkBounce = false
    /// Text editing happens in place. `isEditing` swaps the label for a field
    /// and `fieldFocused` drives the keyboard — two flags rather than one
    /// because the field has to exist before focus can land on it.
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isHistory: Bool { mode == .history }
    private var showsVerdict: Bool {
        mode != .planned && todo.verdict != nil && todo.verdict?.accepted != false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            checkbox
            VStack(alignment: .leading, spacing: 6) {
                titleLine
                if showsVerdict, let verdict = todo.verdict {
                    verdictSubRow(verdict)
                }
            }
            Spacer(minLength: 0)
            authorAvatar
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipe }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingSwipe }
        .contextMenu { contextMenu }
    }

    // MARK: - Title

    /// The todo's own text, and the way to change it: tap it and it becomes a
    /// field in place, keyboard up, caret waiting — no menu, no modal, no
    /// hunting for a Save button. Return commits; tapping away commits too,
    /// which is what "I'm done here" means on a phone. A past day is a record
    /// rather than a draft, so history stays a plain label.
    @ViewBuilder
    private var titleLine: some View {
        if isEditing {
            TextField("Todo", text: $draft, axis: .vertical)
                .font(.body)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit(commitEdit)
                // Losing focus is a commit, not a cancel: the keyboard going
                // away by any route should keep what was typed.
                .onChange(of: fieldFocused) { _, focused in
                    if !focused, isEditing { commitEdit() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(todo.text)
                .font(.body)
                .strikethrough(todo.isDone)
                .foregroundStyle(todo.isDone || isHistory ? .secondary : .primary)
                // The whole width of the line is the target, not just the
                // glyphs — a two-word todo would otherwise be a tiny thing to
                // hit. The verdict sub-row keeps its own taps: it sits outside
                // this shape, so Accept and Dismiss are unaffected.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
                .accessibilityAddTraits(isHistory ? [] : .isButton)
                .accessibilityHint(isHistory ? "" : "Edit this todo")
        }
    }

    private func beginEditing() {
        guard !isHistory else { return }
        Haptics.tap()
        draft = todo.text
        isEditing = true
        // The field has to be in the tree before focus can reach it.
        Task { @MainActor in
            await Task.yield()
            fieldFocused = true
        }
    }

    /// Blank is not an edit — a cleared field restores the original rather
    /// than leaving a nameless row behind. Deleting is the swipe, deliberately.
    private func commitEdit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != todo.text {
            _ = store.editTodoText(todo.id, to: trimmed)
        }
        isEditing = false
        fieldFocused = false
    }

    // MARK: - Author

    /// Who added this, on the trailing edge — only in a shared group, where it
    /// is the one thing the row can't otherwise say.
    @ViewBuilder
    private var authorAvatar: some View {
        if let member = store.author(of: todo) {
            // Two initials can't say which Krithik; the spoken label spells
            // the whole name out, from the address book when this device has
            // one.
            MemberAvatar(member: member)
                .accessibilityLabel("Added by " + ContactNames.shared.label(
                    for: member,
                    signedInAs: store.currentPhone,
                    fallback: store.memberLabel(member)
                ))
        }
    }

    // MARK: - Checkbox

    @ViewBuilder
    private var checkbox: some View {
        if isHistory {
            checkboxImage
                .accessibilityLabel(todo.isDone ? "Done" : "Not done")
        } else {
            Button {
                complete()
            } label: {
                checkboxImage
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isDone ? "Mark as not done" : "Mark as done")
        }
    }

    private var checkboxImage: some View {
        Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(todo.isDone ? Color.manasAccent : Color(uiColor: .tertiaryLabel))
            .contentTransition(.symbolEffect(.replace))
            .scaleEffect(checkBounce ? 1.28 : 1)
    }

    /// Toggling gives the firm completion feedback and a quick spring pop on
    /// the glyph so checking something off feels physical.
    private func complete() {
        Haptics.bump()
        store.toggleDone(todo.id)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { checkBounce = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { checkBounce = false }
        }
    }

    // MARK: - Verdict

    /// The judge's read: a status chip and one line of evidence. When the user
    /// hasn't ruled on it yet, accept/dismiss ghost buttons sit beneath.
    private func verdictSubRow(_ verdict: Verdict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Chip(text: verdict.status.label, systemImage: verdict.status.systemImage, tint: verdict.status.tint)
                Text(verdict.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if verdict.accepted == nil {
                HStack(spacing: 4) {
                    Button("Accept") {
                        Haptics.tap()
                        store.setVerdictAccepted(todo.id, accepted: true)
                    }
                    .buttonStyle(.ghost)
                    Button("Dismiss") {
                        Haptics.tap()
                        store.setVerdictAccepted(todo.id, accepted: false)
                    }
                    .buttonStyle(.ghost)
                }
                .padding(.leading, -9) // pull the ghost padding back to the text edge
            }
        }
    }

    // MARK: - Swipe actions

    @ViewBuilder
    private var leadingSwipe: some View {
        if !isHistory {
            Button {
                complete()
            } label: {
                Label(todo.isDone ? "Undo" : "Complete",
                      systemImage: todo.isDone ? "arrow.uturn.left" : "checkmark")
            }
            .tint(todo.isDone ? .secondary : .manasAccent)
        }
    }

    @ViewBuilder
    private var trailingSwipe: some View {
        if isHistory, !todo.isDone {
            Button {
                Haptics.tap()
                store.moveToToday(todo.id)
            } label: {
                Label("To today", systemImage: "arrow.uturn.up")
            }
            .tint(.manasAccent)
        } else if !isHistory {
            Button(role: .destructive) {
                Haptics.bump()
                store.removeTodo(todo.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if !isHistory {
            // Kept as the discoverable, spoken-out-loud route to the same
            // in-place edit the tap starts — the menu is where someone looks
            // when they don't yet know the text is tappable.
            Button {
                beginEditing()
            } label: { Label("Edit", systemImage: "pencil") }

            // Somebody else's line in a shared group can be ticked off or
            // deleted, but not re-filed out of the group you both share.
            if store.isAuthoredByCurrentUser(todo) {
                moveToGroupMenu
            }

            if !todo.isDone {
                Button {
                    Haptics.tap()
                    onReschedule(todo)
                } label: { Label("Reschedule…", systemImage: "calendar") }
            }

            Button(role: .destructive) {
                Haptics.bump()
                store.removeTodo(todo.id)
            } label: { Label("Delete", systemImage: "trash") }
        } else if !todo.isDone {
            Button {
                Haptics.tap()
                store.moveToToday(todo.id)
            } label: { Label("Move to today", systemImage: "arrow.uturn.up") }
        }
    }

    private var moveToGroupMenu: some View {
        Menu {
            Button {
                Haptics.tap()
                store.setTodoGroup(todo.id, to: .ungrouped)
            } label: {
                Label("None", systemImage: todo.destination == .ungrouped ? "checkmark" : "tray")
            }
            ForEach(store.availableDestinations, id: \.key) { destination in
                Button {
                    Haptics.tap()
                    store.setTodoGroup(todo.id, to: destination)
                } label: {
                    // Moving into a shared bucket publishes the todo to the
                    // other members, so the menu says which entries do that.
                    let name = destination.group ?? ""
                    let title = destination.isShared
                        ? "\(store.emoji(for: destination)) \(name) · shared"
                        : "\(store.emoji(for: destination)) \(name)"
                    Label(title, systemImage: todo.destination == destination ? "checkmark" : "")
                }
            }
        } label: {
            Label("Move to group", systemImage: "folder")
        }
    }
}
