import SwiftUI

/// The day control panel for iPhone: one continuous vertical feed of days.
/// Past days that carry todos recede above (dimmed, oldest first so the newest
/// sits just over Today), Today is the prominent anchor the feed opens on, and
/// planned future days extend below. A compose bar floats above the keyboard
/// and always adds to today. The composition reuses the shared store accessors
/// (`pastDays` / `todoGroups(on:)` / `upcomingDays`) so the two platforms stay
/// in lockstep.
struct MobileDayFeedView: View {
    @Environment(AppStore.self) private var store

    /// Edit and reschedule present from the feed rather than from a row, so a
    /// scroll that recycles the row can't tear down the sheet mid-interaction.
    @State private var editingTodo: Todo?
    @State private var editText = ""
    @State private var reschedulingTodo: Todo?

    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date()) }

    /// Top-to-bottom: past days with todos (oldest first), Today, then planned
    /// future days (soonest first). Only days that actually carry todos appear
    /// around Today, so the feed is real history and real plans — never a wall
    /// of empty days.
    private var feedDays: [FeedDay] {
        let past = store.pastDays.map(\.day).sorted().map { FeedDay(date: $0, kind: .past) }
        let future = store.upcomingDays.map(\.day).sorted().map { FeedDay(date: $0, kind: .future) }
        return past + [FeedDay(date: today, kind: .today)] + future
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileFeedHeader()
            feedList
        }
        .background(Color.manasBackground)
        .safeAreaInset(edge: .bottom) {
            MobileAddBar(day: today)
        }
        .alert("Edit todo", isPresented: editAlertPresented) {
            TextField("Todo", text: $editText)
            Button("Cancel", role: .cancel) { editingTodo = nil }
            Button("Save") {
                if let editingTodo { store.editTodoText(editingTodo.id, to: editText) }
                editingTodo = nil
            }
        }
        .sheet(item: $reschedulingTodo) { todo in
            RescheduleSheet(todo: todo)
                .presentationDetents([.medium])
        }
    }

    // MARK: - Feed

    private var feedList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(feedDays) { feedDay in
                    Section {
                        DaySectionBody(feedDay: feedDay, onEdit: beginEdit, onReschedule: { reschedulingTodo = $0 })
                    } header: {
                        DayHeaderLabel(date: feedDay.date, kind: feedDay.kind)
                    }
                    .listRowBackground(Color.surfaceRaised)
                    .id(feedDay.date)
                    // Past days recede; today and future read at full strength.
                    .opacity(feedDay.kind == .past ? 0.68 : 1)
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { anchorToday(proxy) }
        }
    }

    /// Opens the feed already scrolled to Today, without a visible jump from
    /// the oldest past day.
    private func anchorToday(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(today, anchor: .top) }
        }
    }

    // MARK: - Edit plumbing

    private func beginEdit(_ todo: Todo) {
        editText = todo.text
        editingTodo = todo
    }

    private var editAlertPresented: Binding<Bool> {
        Binding(get: { editingTodo != nil }, set: { if !$0 { editingTodo = nil } })
    }
}

/// One day in the feed, tagged by where it sits relative to Today.
struct FeedDay: Identifiable, Hashable {
    enum Kind { case past, today, future }
    let date: Date
    let kind: Kind
    var id: Date { date }
}

// MARK: - Day section

/// The rows under a day header: the ungrouped cluster first, then each group
/// with an emoji-badged label. Empty days get a friendly one-liner.
private struct DaySectionBody: View {
    @Environment(AppStore.self) private var store
    let feedDay: FeedDay
    var onEdit: (Todo) -> Void
    var onReschedule: (Todo) -> Void

    private var mode: MobileTodoRow.Mode {
        switch feedDay.kind {
        case .today: .today
        case .past: .history
        case .future: .planned
        }
    }

    var body: some View {
        let groups = store.todoGroups(on: feedDay.date)
        if groups.isEmpty {
            EmptyDayRow(kind: feedDay.kind)
        } else {
            ForEach(groups) { group in
                if let label = group.group {
                    GroupHeaderRow(label: label, emoji: store.emoji(forGroup: label),
                                   done: group.todos.filter(\.isDone).count, total: group.todos.count)
                }
                ForEach(group.todos) { todo in
                    MobileTodoRow(todo: todo, mode: mode, onEdit: onEdit, onReschedule: onReschedule)
                }
            }
        }
    }
}

/// A group's badge, label, and done/total tally, set apart from its todos.
private struct GroupHeaderRow: View {
    let label: String
    let emoji: String
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 7) {
            Text(emoji).font(.subheadline)
            Text(label).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(done)/\(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyDayRow: View {
    let kind: FeedDay.Kind

    private var copy: String {
        switch kind {
        case .today: "Nothing planned yet — add the first thing."
        case .future: "Open. Plan something for this day."
        case .past: "Nothing was planned."
        }
    }

    var body: some View {
        Text(copy)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
    }
}

/// A day header in the shared vocabulary: Today in accent, past muted, future
/// neutral. Adjacent days pick up a secondary calendar date the way the mac
/// header does.
private struct DayHeaderLabel: View {
    let date: Date
    let kind: FeedDay.Kind

    private var showsCalendarDate: Bool {
        let calendar = Calendar.current
        let offset = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)
        ).day ?? 0
        return abs(offset) <= 1
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DayLabel.title(for: date))
                .font(.headline)
                .foregroundStyle(titleStyle)
                .textCase(nil)
            if showsCalendarDate {
                Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    private var titleStyle: AnyShapeStyle {
        switch kind {
        case .today: AnyShapeStyle(Color.manasAccent)
        case .past: AnyShapeStyle(.secondary)
        case .future: AnyShapeStyle(.primary)
        }
    }
}

// MARK: - Reschedule sheet

/// A compact graphical date picker behind "Reschedule…". Confirming re-dates
/// the todo (which clears any stale verdict in the store).
private struct RescheduleSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let todo: Todo
    @State private var pickedDate: Date

    init(todo: Todo) {
        self.todo = todo
        _pickedDate = State(initialValue: Calendar.current.startOfDay(for: todo.day))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                DatePicker("Move to", selection: $pickedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(.manasAccent)
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Reschedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        Haptics.tap()
                        store.rescheduleTodo(todo.id, to: pickedDate)
                        dismiss()
                    }
                    .tint(.manasAccent)
                }
            }
        }
    }
}
