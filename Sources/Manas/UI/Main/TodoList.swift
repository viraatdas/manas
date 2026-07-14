import SwiftUI

/// The rounded add field pinned above the todo list. Submits on return and
/// keeps focus so several todos can be entered in a row.
struct AddTodoField: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            TextField("Add a todo", text: $draft)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isFocused)
                .onSubmit(submit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
        )
    }

    private func submit() {
        guard store.addTodo(draft) != nil else { return }
        draft = ""
        isFocused = true
    }
}

/// The judged todo list — the primary content of Screen 1. One flat card of
/// rows; a gentle empty state when there is nothing on the list.
struct TodoListSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.todos.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ForEach(store.todos) { todo in
                    TodoRow(todo: todo)
                    if todo.id != store.todos.last?.id {
                        Divider().padding(.leading, 38)
                    }
                }
            }
            .manasCard(padding: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("Nothing planned yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Add a todo above, then ask Claude how the day went.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// One todo: checkbox and text, plus — while an unsettled verdict exists — an
/// indented sub-row with the verdict chip, one-line evidence, and
/// accept/dismiss ghost buttons. Checked-off items collapse to strikethrough
/// secondary text with no chip.
struct TodoRow: View {
    @Environment(AppStore.self) private var store
    var todo: Todo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            checkbox
            VStack(alignment: .leading, spacing: 5) {
                Text(todo.text)
                    .font(.body)
                    .strikethrough(todo.isDone)
                    .foregroundStyle(todo.isDone ? .secondary : .primary)
                if !todo.isDone, let verdict = todo.verdict, verdict.accepted != false {
                    verdictSubRow(verdict)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var checkbox: some View {
        Button {
            store.toggleDone(todo.id)
        } label: {
            Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(todo.isDone ? Color.manasAccent : Color(nsColor: .tertiaryLabelColor))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(todo.isDone ? "Mark as not done" : "Mark as done")
    }

    private func verdictSubRow(_ verdict: Verdict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Chip(
                    text: verdict.status.label,
                    systemImage: verdict.status.systemImage,
                    tint: verdict.status.tint
                )
                Text(verdict.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if verdict.accepted == nil {
                HStack(spacing: 2) {
                    Button("Accept") {
                        store.setVerdictAccepted(todo.id, accepted: true)
                    }
                    .buttonStyle(.ghost)
                    Button("Dismiss", action: dismissVerdict)
                        .buttonStyle(.ghost)
                }
                .padding(.leading, -8)
            }
        }
    }

    /// Dismissing throws the verdict away entirely, so the row goes back to a
    /// plain todo the judge can weigh in on next check.
    private func dismissVerdict() {
        guard let index = store.todos.firstIndex(where: { $0.id == todo.id }) else { return }
        store.todos[index].verdict = nil
    }
}

#Preview("Todo list, judged") {
    VStack(spacing: 12) {
        AddTodoField()
        TodoListSection()
    }
    .environment(AppStore.previewJudged)
    .padding(16)
    .frame(width: 420)
    .background(Color.manasBackground)
}

#Preview("Todo list, empty") {
    VStack(spacing: 12) {
        AddTodoField()
        TodoListSection()
    }
    .environment(AppStore.previewEmpty)
    .padding(16)
    .frame(width: 420)
    .background(Color.manasBackground)
}
