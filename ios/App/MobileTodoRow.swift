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
    /// Hoisted to the feed so the edit alert and reschedule sheet present from
    /// a stable owner rather than from inside a row that may scroll away.
    var onEdit: (Todo) -> Void
    var onReschedule: (Todo) -> Void

    @State private var checkBounce = false

    private var isHistory: Bool { mode == .history }
    private var showsVerdict: Bool {
        mode != .planned && todo.verdict != nil && todo.verdict?.accepted != false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            checkbox
            VStack(alignment: .leading, spacing: 6) {
                Text(todo.text)
                    .font(.body)
                    .strikethrough(todo.isDone)
                    .foregroundStyle(todo.isDone || isHistory ? .secondary : .primary)
                if showsVerdict, let verdict = todo.verdict {
                    verdictSubRow(verdict)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipe }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingSwipe }
        .contextMenu { contextMenu }
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
            Button {
                Haptics.tap()
                onEdit(todo)
            } label: { Label("Edit", systemImage: "pencil") }

            moveToGroupMenu

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
                store.setTodoGroup(todo.id, group: nil)
            } label: {
                Label("None", systemImage: todo.group == nil ? "checkmark" : "tray")
            }
            ForEach(store.availableTodoGroups, id: \.self) { group in
                Button {
                    Haptics.tap()
                    store.setTodoGroup(todo.id, group: group)
                } label: {
                    let isCurrent = todo.group.map { TodoGroupName.key(for: $0) } == TodoGroupName.key(for: group)
                    Label("\(store.emoji(forGroup: group)) \(group)", systemImage: isCurrent ? "checkmark" : "")
                }
            }
        } label: {
            Label("Move to group", systemImage: "folder")
        }
    }
}
