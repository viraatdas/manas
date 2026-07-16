import SwiftUI

/// Planned-ahead days below today's content: one muted section per future
/// day — a lighter card of plain rows with a compact add field of its own —
/// and "+ Plan a day…" at the bottom, which opens a calendar restricted to
/// future dates. Future todos are never judged, so there is no verdict UI
/// down here.
struct UpcomingSection: View {
    @Environment(AppStore.self) private var store
    /// Days planned this session that have no todos yet. They stay visible
    /// so the new day's add field has somewhere to live before the first
    /// todo; an empty day is not persisted across relaunch.
    @State private var plannedEmptyDays: Set<Date>
    @FocusState private var focusedAddDay: Date?
    @State private var showingPlanner = false

    init(initiallyPlanned: Set<Date> = []) {
        _plannedEmptyDays = State(initialValue: initiallyPlanned)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(sections) { group in
                UpcomingDaySection(group: group, focusedAddDay: $focusedAddDay)
            }
            planButton
        }
    }

    /// Store-backed upcoming days merged with this session's still-empty
    /// planned days, soonest first.
    private var sections: [DayGroup] {
        var groups = store.upcomingDays
        let known = Set(groups.map(\.day))
        let today = Calendar.current.startOfDay(for: Date())
        for day in plannedEmptyDays where !known.contains(day) && day > today {
            groups.append(DayGroup(day: day, todos: []))
        }
        return groups.sorted { $0.day < $1.day }
    }

    private var planButton: some View {
        Button("+ Plan a day…") {
            showingPlanner = true
        }
        .buttonStyle(.ghost)
        .padding(.leading, -8)
        .accessibilityLabel("Plan a day")
        .popover(isPresented: $showingPlanner, arrowEdge: .bottom) {
            PlanDayPicker(onPick: plan)
        }
    }

    private func plan(_ day: Date) {
        let planned = Calendar.current.startOfDay(for: day)
        showingPlanner = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            _ = plannedEmptyDays.insert(planned)
        }
        // Focus once the new section exists and the popover has let go of
        // the responder chain.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            focusedAddDay = planned
        }
    }
}

/// One future day: muted header, then a quiet surface-1 card of plain rows
/// capped by the day's own add field.
private struct UpcomingDaySection: View {
    var group: DayGroup
    var focusedAddDay: FocusState<Date?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DayLabel.title(for: group.day))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(group.todos) { todo in
                    UpcomingTodoRow(todo: todo)
                    Divider().padding(.leading, 42)
                }
                UpcomingAddField(day: group.day, focusedAddDay: focusedAddDay)
            }
            .background(Color.surface1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// A plain planned row: checkbox and text only.
private struct UpcomingTodoRow: View {
    @Environment(AppStore.self) private var store
    var todo: Todo
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    store.toggleDone(todo.id)
                }
            } label: {
                Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(todo.isDone ? Color.manasAccent : Color(nsColor: .tertiaryLabelColor))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isDone ? "Mark as not done" : "Mark as done")
            Text(todo.text)
                .font(.body)
                .strikethrough(todo.isDone)
                .foregroundStyle(todo.isDone ? .tertiary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(isHovered ? 0.025 : 0))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// The compact add field living at the bottom of a future day's card.
/// Submits into that day and keeps focus for quick planning runs; the plus
/// warms to the accent while focused.
private struct UpcomingAddField: View {
    @Environment(AppStore.self) private var store
    var day: Date
    var focusedAddDay: FocusState<Date?>.Binding
    @State private var draft = ""

    private var isFocused: Bool { focusedAddDay.wrappedValue == day }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(isFocused ? Color.manasAccent : Color(nsColor: .tertiaryLabelColor))
            TextField("Add a todo", text: $draft)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused(focusedAddDay, equals: day)
                .onSubmit(submit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private func submit() {
        guard store.addTodo(draft, on: day) != nil else { return }
        draft = ""
        focusedAddDay.wrappedValue = day
    }
}

/// The plan-a-day popover: a graphical calendar restricted to dates after
/// today. Clicking a date plans it immediately; the button below confirms
/// the pre-selected date, since re-picking it fires no change.
struct PlanDayPicker: View {
    var onPick: (Date) -> Void
    @State private var selection = PlanDayPicker.tomorrow()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DatePicker(
                "Plan a day",
                selection: $selection,
                in: Self.tomorrow()...,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .onChange(of: selection) { _, day in
                onPick(day)
            }
            Button("Plan this day") {
                onPick(selection)
            }
            .buttonStyle(.ghost)
        }
        .padding(12)
    }

    static func tomorrow(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
    }
}

#Preview("Upcoming days") {
    UpcomingSection()
        .environment(AppStore.previewTimeline)
        .padding(24)
        .frame(width: 520)
        .background(Color.manasBackground)
}

#Preview("Upcoming, freshly planned empty day") {
    UpcomingSection(initiallyPlanned: [
        Calendar.current.date(
            byAdding: .day, value: 3,
            to: Calendar.current.startOfDay(for: Date())
        )!,
    ])
    .environment(AppStore.previewTimeline)
    .padding(24)
    .frame(width: 520)
    .background(Color.manasBackground)
}

#Preview("Plan a day picker") {
    PlanDayPicker { _ in }
        .background(Color.manasBackground)
}
