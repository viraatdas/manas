import SwiftUI

/// The continuous vertical day feed. Past days that have todos recede above as
/// read-only history, Today is anchored at the top on launch and stays the
/// primary card, and future days extend below with inline add fields so
/// planning ahead is scroll-down-and-type. Replaces the old horizontal
/// carousel and the plan-a-day picker: scroll up for the past, down for the
/// future, and a floating Today pill returns when Today scrolls off-screen.
extension Notification.Name {
    /// Posted by the ⌘L menu command: scroll the feed to Today, then focus
    /// today's compose bar so the user can type immediately.
    static let manasJumpToToday = Notification.Name("dev.viraat.manas.jump-to-today")
    /// Posted by the feed once Today is on screen; today's add field focuses.
    static let manasFocusTodayField = Notification.Name("dev.viraat.manas.focus-today-field")
}

struct DayFeed: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Four months of planning targets are cheap here because LazyVStack only
    /// realizes visible rows. Keeping the data horizon stable is important:
    /// growing it from a row's onAppear mutates layout while AppKit is placing
    /// a focused text cursor and can send the scroll view into a render loop.
    private static let futureHorizon = 120
    @State private var isTodayVisible = true
    @State private var viewportFrame: CGRect = .zero
    /// Today's measured frame, kept so the launch anchor can tell whether the
    /// scroll actually landed instead of assuming it did.
    @State private var todayFrame: CGRect?
    @State private var hasAnchoredToday = false
    /// A future day gets a real NSTextField only while the user is composing
    /// for it. Keeping this selection at feed scope guarantees that scrolling
    /// through the horizon never leaves dozens of live text editors behind.
    @State private var activeFutureEditorDay: Date?

    private let calendar = Calendar.current

    private var today: Date { calendar.startOfDay(for: Date()) }

    /// Top-to-bottom: past days with todos (oldest first), Today, then the
    /// fixed future horizon. Only past days that carry todos appear, so the
    /// history above Today is real, not a wall of empty days.
    private var feedDays: [FeedDay] {
        Self.days(
            past: store.pastDays.map(\.day),
            today: today,
            futureHorizon: Self.futureHorizon,
            calendar: calendar
        )
    }

    /// Pure feed composition, split out so the ordering is unit-testable:
    /// past days oldest-first, then Today, then `futureHorizon` future days.
    static func days(
        past: [Date],
        today: Date,
        futureHorizon: Int,
        calendar: Calendar = .current
    ) -> [FeedDay] {
        let normalizedToday = calendar.startOfDay(for: today)
        var seenPastDays = Set<Date>()
        var days = past
            .map { calendar.startOfDay(for: $0) }
            .filter { $0 < normalizedToday && seenPastDays.insert($0).inserted }
            .sorted()
            .map { FeedDay(date: $0, kind: .past) }
        days.append(FeedDay(date: normalizedToday, kind: .today))
        for offset in 1...max(1, futureHorizon) {
            if let date = calendar.date(byAdding: .day, value: offset, to: normalizedToday) {
                days.append(FeedDay(date: date, kind: .future))
            }
        }
        return days
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(feedDays) { feedDay in
                        Section {
                            DayFeedSection(
                                feedDay: feedDay,
                                activeFutureEditorDay: $activeFutureEditorDay
                            )
                                .frame(maxWidth: ContentView.contentMaxWidth)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 26)
                                .opacity(feedDay.kind == .past ? 0.68 : 1)
                                .background(todayFrameReporter(for: feedDay))
                                .background(dayFrameReporter(for: feedDay))
                                // ScrollViewReader needs one concrete target.
                                // Keep the ID on the section body; putting it
                                // on Section propagates the same ID to both its
                                // flattened header and body and can lock focus
                                // into a full-speed layout loop.
                                .id(feedDay.date)
                        } header: {
                            DayFeedHeader(date: feedDay.date, kind: feedDay.kind)
                        }
                    }
                }
                .padding(.bottom, 44)
            }
            .background(viewportReporter)
            .onPreferenceChange(TodayFramePreferenceKey.self) { frame in
                todayFrame = frame
                let visible = frame.map { $0.intersects(viewportFrame) } ?? true
                guard visible != isTodayVisible else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    isTodayVisible = visible
                }
            }
            .onPreferenceChange(DayFramePreferenceKey.self) { frames in
                updateVisibleDay(from: frames)
            }
            .overlay(alignment: .bottom) { todayPill }
            .onAppear { anchorToday(using: proxy) }
            .onReceive(NotificationCenter.default.publisher(for: .manasJumpToToday)) { _ in
                jumpToTodayAndCompose(using: proxy)
            }
        }
    }

    // MARK: - Today anchoring & pill

    /// Brings Today to the top of the viewport after first layout, without a
    /// visible jump: the feed starts scrolled to Today rather than the oldest
    /// past day.
    ///
    /// One `scrollTo` was not enough. The feed is a LazyVStack, so on the first
    /// pass only a handful of sections exist and the rest are height estimates;
    /// a scroll aimed at a day it has not built yet lands short, and the app
    /// could open a week deep in history. So nudge, measure where Today
    /// actually ended up, and nudge again until it arrives — each pass realizes
    /// more of the feed, so the estimates converge on the truth within a few
    /// frames and the loop then stops for good.
    private func anchorToday(using proxy: ScrollViewProxy) {
        guard !hasAnchoredToday else { return }
        Task { @MainActor in
            for _ in 0..<12 {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(today, anchor: .top)
                }
                try? await Task.sleep(for: .milliseconds(32))
                if isTodayAnchored { break }
            }
            hasAnchoredToday = true
        }
    }

    /// Whether Today's section has actually come to rest at the top of the
    /// viewport. The tolerance covers the pinned day header sitting over the
    /// section's first rows; anything beyond it means the scroll landed on a
    /// different day.
    private var isTodayAnchored: Bool {
        guard viewportFrame.height > 0, let todayFrame else { return false }
        return abs(todayFrame.minY - viewportFrame.minY) < 80
    }

    /// ⌘L (also the header button and the floating pill): bring Today to the
    /// top, then (once its section is materialized and the scroll has settled)
    /// hand focus to the compose bar. The focus hop is a second notification
    /// because a LazyVStack may not have built today's field yet when the
    /// command fires from far away in the feed.
    private func jumpToTodayAndCompose(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                proxy.scrollTo(today, anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(280))
            // Coming from far down the feed, that first hop crosses days the
            // LazyVStack has not built and can land short — the same reason
            // the launch anchor has to re-check. Correct silently rather than
            // animating a second time, so a good jump stays a single motion.
            for _ in 0..<8 where !isTodayAnchored {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(today, anchor: .top)
                }
                try? await Task.sleep(for: .milliseconds(32))
            }
            NotificationCenter.default.post(name: .manasFocusTodayField, object: nil)
        }
    }

    @ViewBuilder
    private var todayPill: some View {
        if !isTodayVisible {
            // Routed through the same notification as the Go ▸ Today menu item
            // and the header button, so all three land identically. It used to
            // scroll without focusing and carried its own ⌘T, which meant the
            // app answered to two different shortcuts for one action — and the
            // pill's only worked while the pill happened to be on screen.
            Button {
                NotificationCenter.default.post(name: .manasJumpToToday, object: nil)
            } label: {
                Label("Today", systemImage: "location.fill")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.manasAccent)
            .controlSize(.regular)
            .help("Jump to today (⌘L)")
            .padding(.bottom, 14)
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
    }

    // MARK: - Visibility plumbing

    /// Publishes Today's frame (in global space) so the feed knows when to
    /// show the Today pill.
    @ViewBuilder
    private func todayFrameReporter(for feedDay: FeedDay) -> some View {
        if feedDay.kind == .today {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TodayFramePreferenceKey.self,
                    value: geometry.frame(in: .global)
                )
            }
        }
    }

    /// Publishes every realized day's frame so the header can name the one at
    /// the top of the viewport.
    private func dayFrameReporter(for feedDay: FeedDay) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: DayFramePreferenceKey.self,
                value: [feedDay.date: geometry.frame(in: .global)]
            )
        }
    }

    /// The day at the top of the viewport is whichever section straddles the
    /// top edge; when a gap does, the next one down. Only realized sections
    /// report, which is fine — LazyVStack always has the visible ones built.
    private func updateVisibleDay(from frames: [Date: CGRect]) {
        guard viewportFrame.height > 0, !frames.isEmpty else { return }
        let top = viewportFrame.minY
        let straddling = frames.first { $0.value.minY <= top && $0.value.maxY > top }?.key
        let nextDown = frames.filter { $0.value.minY > top }.min { $0.value.minY < $1.value.minY }?.key
        guard let day = straddling ?? nextDown, day != store.visibleFeedDay else { return }
        store.visibleFeedDay = day
    }

    /// Tracks the scroll viewport's own rect so intersection with Today's
    /// frame is a plain geometry test that works on macOS 14.
    private var viewportReporter: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { viewportFrame = geometry.frame(in: .global) }
                .onChange(of: geometry.size) { _, _ in
                    viewportFrame = geometry.frame(in: .global)
                }
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

private struct DayFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Date: CGRect] = [:]
    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue()) { _, incoming in incoming }
    }
}

private struct TodayFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// A pinned day header. Today reads in accent; past and future are muted. The
/// material keeps the label legible as its section scrolls beneath it.
struct DayFeedHeader: View {
    let date: Date
    let kind: FeedDay.Kind

    /// Today/Tomorrow/Yesterday get a secondary calendar date; everything else
    /// already spells out its date in the title, so a second copy is dropped.
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
            if showsCalendarDate {
                Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: ContentView.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.manasBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.hairline).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DayLabel.title(for: date))
    }

    /// Today carries the accent; past days recede; future days stay neutral.
    private var titleStyle: AnyShapeStyle {
        switch kind {
        case .today: AnyShapeStyle(Color.manasAccent)
        case .past: AnyShapeStyle(.secondary)
        case .future: AnyShapeStyle(.primary)
        }
    }
}

/// The body under a day header: Today gets the add field, its list, and the
/// discovered card; future days get an add field so planning is type-ahead;
/// past days are read-only history.
struct DayFeedSection: View {
    @Environment(AppStore.self) private var store
    let feedDay: FeedDay
    @Binding private var activeFutureEditorDay: Date?

    init(
        feedDay: FeedDay,
        activeFutureEditorDay: Binding<Date?> = .constant(nil)
    ) {
        self.feedDay = feedDay
        _activeFutureEditorDay = activeFutureEditorDay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch feedDay.kind {
            case .today:
                AddTodoField(day: feedDay.date)
                TodoListSection(day: feedDay.date)
                DiscoveredSection()
            case .future:
                futureComposer
                if !store.todos(on: feedDay.date).isEmpty {
                    TodoListSection(day: feedDay.date)
                }
            case .past:
                TodoListSection(day: feedDay.date)
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var futureComposer: some View {
        if activeFutureEditorDay == feedDay.date {
            AddTodoField(
                day: feedDay.date,
                focusOnAppear: true,
                onCancel: { activeFutureEditorDay = nil }
            )
        } else {
            Button {
                activeFutureEditorDay = feedDay.date
            } label: {
                Label("Add a todo", systemImage: "plus")
            }
            .buttonStyle(.ghost)
            .accessibilityLabel("Add a todo to \(DayLabel.title(for: feedDay.date))")
        }
    }
}

#Preview("Day feed") {
    DayFeed()
        .environment(AppStore.previewTimeline)
        // Group headers reach for the sync session to offer sharing.
        .environment(SyncController())
        .frame(width: 560, height: 640)
        .background(Color.manasBackground)
}

#Preview("Day feed · empty") {
    DayFeed()
        .environment(AppStore.previewEmpty)
        .environment(SyncController())
        .frame(width: 560, height: 640)
        .background(Color.manasBackground)
}
