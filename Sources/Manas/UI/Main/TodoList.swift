import SwiftUI

/// Date-scoped add field. The visible pager day and this field always share
/// the same normalized date, so adding while looking at Friday cannot land on
/// today by accident.
struct AddTodoField: View {
    @Environment(AppStore.self) private var store
    var day: Date
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    init(day: Date = Date()) {
        self.day = Calendar.current.startOfDay(for: day)
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isFocused ? Color.manasAccent : .secondary)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isFocused)
                .onSubmit(submit)
                .accessibilityLabel(placeholder)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.manasAccent.opacity(0.7) : Color.hairline,
                    lineWidth: isFocused ? 1 : 0.5
                )
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var placeholder: String {
        switch Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: day
        ).day {
        case 0: "Add to today"
        case -1: "Add to yesterday"
        case 1: "Add to tomorrow"
        default: "Add to \(day.formatted(.dateTime.weekday(.wide)))"
        }
    }

    private func submit() {
        guard store.addTodo(draft, on: day) != nil else { return }
        draft = ""
        isFocused = true
    }
}

struct TodoListSection: View {
    @Environment(AppStore.self) private var store
    var day: Date

    init(day: Date = Date()) {
        self.day = Calendar.current.startOfDay(for: day)
    }

    private var mode: TodoRow.Mode {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return .today }
        return day < calendar.startOfDay(for: Date()) ? .history : .planned
    }

    var body: some View {
        let todos = store.todos(on: day)
        if todos.isEmpty {
            DayEmptyState(day: day)
        } else {
            VStack(spacing: 0) {
                ForEach(todos) { todo in
                    TodoRow(todo: todo, mode: mode)
                    if todo.id != todos.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .manasCard(padding: 0)
        }
    }
}

private struct DayEmptyState: View {
    var day: Date

    private var copy: (icon: String, title: String, detail: String) {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            return (
                "checklist",
                "Your day is open",
                "Add a todo above. Manas will compare it with what you actually do."
            )
        }
        if day < calendar.startOfDay(for: Date()) {
            return ("calendar.badge.checkmark", "Nothing was planned", "This day has no saved todos.")
        }
        return ("calendar.badge.plus", "Nothing planned yet", "Add a todo above to give this day a head start.")
    }

    var body: some View {
        let copy = copy
        VStack(spacing: 8) {
            Image(systemName: copy.icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(copy.title)
                .font(.headline)
            Text(copy.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }
}

/// One visual vocabulary for today, settled history, and future planning.
/// Only the behavior varies by mode; row alignment and controls stay stable.
struct TodoRow: View {
    enum Mode {
        case today
        case history
        case planned
    }

    @Environment(AppStore.self) private var store
    var todo: Todo
    var mode: Mode = .today
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            checkbox
            VStack(alignment: .leading, spacing: 6) {
                Text(todo.text)
                    .font(.body)
                    .strikethrough(todo.isDone)
                    .foregroundStyle(todo.isDone || mode == .history ? .secondary : .primary)
                    .textSelection(.enabled)
                if !todo.isDone, mode != .planned,
                   let verdict = todo.verdict, verdict.accepted != false {
                    verdictSubRow(verdict)
                }
            }
            Spacer(minLength: 8)
            if mode == .history, !todo.isDone {
                Button("Move to today") {
                    store.moveToToday(todo.id)
                }
                .buttonStyle(.ghost)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(isHovered ? 0.035 : 0))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var checkbox: some View {
        if mode == .history {
            checkboxImage
                .accessibilityLabel(todo.isDone ? "Done" : "Not done")
        } else {
            Button {
                store.toggleDone(todo.id)
            } label: {
                checkboxImage
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isDone ? "Mark as not done" : "Mark as done")
        }
    }

    private var checkboxImage: some View {
        Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
            .font(.body)
            .foregroundStyle(todo.isDone ? Color.manasAccent : Color(nsColor: .tertiaryLabelColor))
            .contentTransition(.symbolEffect(.replace))
    }

    private func verdictSubRow(_ verdict: Verdict) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Chip(
                    text: verdict.status.label,
                    systemImage: verdict.status.systemImage,
                    tint: verdict.status.tint
                )
                Text(verdict.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if mode == .today, verdict.accepted == nil {
                HStack(spacing: 2) {
                    Button("Accept") {
                        store.setVerdictAccepted(todo.id, accepted: true)
                    }
                    .buttonStyle(.ghost)
                    Button("Dismiss", action: dismissVerdict)
                        .buttonStyle(.ghost)
                }
                .padding(.leading, -9)
            }
        }
    }

    private func dismissVerdict() {
        guard let index = store.todos.firstIndex(where: { $0.id == todo.id }) else { return }
        store.todos[index].verdict = nil
    }
}

#Preview("Date-scoped todo list") {
    VStack(spacing: 16) {
        AddTodoField()
        TodoListSection()
    }
    .environment(AppStore.previewJudged)
    .padding(24)
    .frame(width: 520)
    .background(Color.manasBackground)
}
