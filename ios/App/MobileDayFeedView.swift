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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reschedule presents from the feed rather than from a row, so a scroll
    /// that recycles the row can't tear down the sheet mid-interaction. Text
    /// editing needs no such hoisting — it happens inside the row and presents
    /// nothing, so it lives there.
    @State private var reschedulingTodo: Todo?
    @State private var sharingGroup: SharedGroupTarget?
    /// Bumped by the header to ask the feed to return to today. A counter
    /// rather than a flag so a second tap scrolls again instead of being
    /// swallowed as "no change".
    @State private var todayRequests = 0

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
            MobileFeedHeader { todayRequests += 1 }
            feedList
        }
        .background(Color.manasBackground)
        .safeAreaInset(edge: .bottom) {
            MobileAddBar(day: today)
        }
        .sheet(item: $reschedulingTodo) { todo in
            RescheduleSheet(todo: todo)
                .presentationDetents([.medium])
        }
        .sheet(item: $sharingGroup) { target in
            MobileShareGroupSheet(target: target)
        }
    }

    // MARK: - Feed

    private var feedList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(feedDays) { feedDay in
                    Section {
                        DaySectionBody(
                            feedDay: feedDay,
                            onReschedule: { reschedulingTodo = $0 },
                            onShare: { sharingGroup = $0 }
                        )
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
            // Match the desktop's warm neutral instead of iOS's cooler gray.
            .scrollContentBackground(.hidden)
            .background(Color.manasBackground)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { anchorToday(proxy) }
            // A tap on the header glides rather than teleports: the launch
            // anchor has to be invisible, but this one is a response to a
            // deliberate tap, so the travel is what says it worked.
            .onChange(of: todayRequests) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                    proxy.scrollTo(today, anchor: .top)
                }
            }
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
    var onReschedule: (Todo) -> Void
    var onShare: (SharedGroupTarget) -> Void

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
                // Folding is per group *per day* — the feed stacks every day
                // in one scroll view and most of them own a Work and a
                // Personal — and a shared group folds on its share, not its
                // label, since two buckets may carry the same name.
                let key = SectionKey.group(group.destination, on: feedDay.date)
                let collapsed = group.group != nil && store.isCollapsed(key)
                if let label = group.group {
                    GroupHeaderRow(label: label, emoji: store.emoji(for: group.destination),
                                   done: group.todos.filter(\.isDone).count, total: group.todos.count,
                                   wastedMinutes: TodoGroupName.key(for: label) == TodoGroupName.key(for: TodoGroupName.wasteOfTime)
                                       ? store.wastedMinutes(on: feedDay.date) : nil,
                                   members: group.shareID.flatMap {
                                       store.sharedGroup(id: $0)?.members(excluding: store.currentPhone)
                                   } ?? [],
                                   isCollapsed: collapsed) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            store.toggleCollapsed(key)
                        }
                    }
                    .contextMenu {
                        Button {
                            Haptics.tap()
                            onShare(SharedGroupTarget(label: label, shareID: group.shareID))
                        } label: {
                            Label(
                                group.shareID == nil ? "Share group…" : "Sharing…",
                                systemImage: "person.badge.plus"
                            )
                        }
                    }
                }
                if !collapsed {
                    ForEach(group.todos) { todo in
                        MobileTodoRow(todo: todo, mode: mode, onReschedule: onReschedule)
                    }
                }
            }
        }
    }
}

/// A group's badge, label, and done/total tally, set apart from its todos.
/// Tapping anywhere along the row folds the group away — the whole row rather
/// than the chevron alone, which is a hard target for a thumb. A shared group
/// also wears the people in it, which is what tells it apart from a private
/// bucket at a glance.
private struct GroupHeaderRow: View {
    let label: String
    let emoji: String
    let done: Int
    let total: Int
    var wastedMinutes: Int?
    var members: [SharedGroupMember] = []
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(emoji).font(.subheadline)
                Text(label).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(done)/\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let wastedMinutes {
                    Text("\(wastedMinutes) min")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !members.isEmpty {
                    MemberAvatarStack(members: members, size: 17)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            members.isEmpty
                ? "\(label), \(done) of \(total) done"
                : "\(label), shared with \(members.count), \(done) of \(total) done"
        )
        .accessibilityHint(isCollapsed ? "Expand group" : "Collapse group")
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
