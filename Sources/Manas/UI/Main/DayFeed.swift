import SwiftUI

/// The continuous vertical day feed. Past days that have todos recede above as
/// read-only history, Today is anchored at the top on launch and stays the
/// primary card, and future days extend below with inline add fields so
/// planning ahead is scroll-down-and-type. Replaces the old horizontal
/// carousel and the plan-a-day picker: scroll up for the past, down for the
/// future, and a floating Today pill returns when Today scrolls off-screen.
struct DayFeed: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How many future days are materialized right now; grows as the user
    /// nears the bottom so the horizon feels endless without building it all.
    @State private var futureHorizon = 7
    @State private var isTodayVisible = true
    @State private var viewportFrame: CGRect = .zero

    private let calendar = Calendar.current
    private static let maxFutureHorizon = 120

    private var today: Date { calendar.startOfDay(for: Date()) }

    /// Top-to-bottom: past days with todos (oldest first), Today, then the
    /// rolling future horizon. Only past days that carry todos appear, so the
    /// history above Today is real, not a wall of empty days.
    private var feedDays: [FeedDay] {
        Self.days(
            past: store.pastDays.map(\.day),
            today: today,
            futureHorizon: futureHorizon,
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
        var days = past
            .map { calendar.startOfDay(for: $0) }
            .sorted()
            .map { FeedDay(date: $0, kind: .past) }
        days.append(FeedDay(date: today, kind: .today))
        for offset in 1...max(1, futureHorizon) {
            if let date = calendar.date(byAdding: .day, value: offset, to: today) {
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
                            DayFeedSection(feedDay: feedDay)
                                .frame(maxWidth: ContentView.contentMaxWidth)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 26)
                                .opacity(feedDay.kind == .past ? 0.68 : 1)
                                .background(todayFrameReporter(for: feedDay))
                                .onAppear { extendHorizonIfNeeded(feedDay) }
                        } header: {
                            DayFeedHeader(date: feedDay.date, kind: feedDay.kind)
                        }
                        .id(feedDay.date)
                    }
                }
                .padding(.bottom, 44)
            }
            .background(viewportReporter)
            .onPreferenceChange(TodayFramePreferenceKey.self) { frame in
                let visible = frame.map { $0.intersects(viewportFrame) } ?? true
                guard visible != isTodayVisible else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    isTodayVisible = visible
                }
            }
            .overlay(alignment: .bottom) { todayPill(proxy) }
            .onAppear { anchorToday(using: proxy) }
        }
    }

    // MARK: - Today anchoring & pill

    /// Brings Today to the top of the viewport after first layout, without a
    /// visible jump: the feed starts scrolled to Today rather than the oldest
    /// past day.
    private func anchorToday(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(today, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func todayPill(_ proxy: ScrollViewProxy) -> some View {
        if !isTodayVisible {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
                    proxy.scrollTo(today, anchor: .top)
                }
            } label: {
                Label("Today", systemImage: "location.fill")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.manasAccent)
            .controlSize(.regular)
            .keyboardShortcut("t", modifiers: [.command])
            .help("Jump to today (⌘T)")
            .padding(.bottom, 14)
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
    }

    // MARK: - Rolling horizon & visibility plumbing

    private func extendHorizonIfNeeded(_ feedDay: FeedDay) {
        guard feedDay.kind == .future,
              feedDay.date == feedDays.last?.date,
              futureHorizon < Self.maxFutureHorizon
        else { return }
        futureHorizon = min(Self.maxFutureHorizon, futureHorizon + 7)
    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch feedDay.kind {
            case .today:
                AddTodoField(day: feedDay.date)
                TodoListSection(day: feedDay.date)
                DiscoveredSection()
            case .future:
                AddTodoField(day: feedDay.date)
                if !store.todos(on: feedDay.date).isEmpty {
                    TodoListSection(day: feedDay.date)
                }
            case .past:
                TodoListSection(day: feedDay.date)
            }
        }
        .padding(.top, 12)
    }
}

#Preview("Day feed") {
    DayFeed()
        .environment(AppStore.previewTimeline)
        .frame(width: 560, height: 640)
        .background(Color.manasBackground)
}

#Preview("Day feed · empty") {
    DayFeed()
        .environment(AppStore.previewEmpty)
        .frame(width: 560, height: 640)
        .background(Color.manasBackground)
}
