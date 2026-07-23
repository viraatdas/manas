import SwiftUI
import WidgetKit

// The Manas "Today" widget. It reads the app's shared state.json out of the
// app group, distills today's todos, and renders them in the same flat,
// hairline, coral-accented language as the mac app: sentence case, system
// text styles, semantic surfaces, no gradients.

@main
struct ManasWidgetBundle: WidgetBundle {
    var body: some Widget {
        ManasTodayWidget()
    }
}

struct ManasTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ManasToday", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Today's todos at a glance.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular,
        ])
    }
}

// MARK: - Shared state

/// Reads and orders today's todos from the keychain snapshot the app writes
/// after every change (see WidgetSharedState — the app ↔ widget channel that
/// needs no portal-registered App Group). All access is funneled through here
/// so the timeline and previews share one code path.
enum TodayStore {
    /// Today's todos in display order for a reference date — unfinished first,
    /// done at the end, each half preserving the stored order (array order is
    /// display order in the app). Returns nil when no snapshot has been
    /// written yet, so callers can fall back to demo data.
    static func snapshot(for referenceDate: Date, calendar: Calendar = .current) -> TodaySnapshot? {
        guard let todos = WidgetSharedState.read() else { return nil }
        return TodaySnapshot(todos: todos, referenceDate: referenceDate, calendar: calendar)
    }
}

/// Today's ordered todos plus the counts the summary views lean on. Pure
/// value type so it can be built from either real or demo todos.
struct TodaySnapshot {
    /// Today's todos, unfinished first (file order), done last (file order).
    var ordered: [Todo]
    var total: Int
    var doneCount: Int

    var remaining: Int { total - doneCount }
    var isEmpty: Bool { total == 0 }
    var allDone: Bool { total > 0 && doneCount == total }
    /// The leading unfinished todos, for the count-first and lock-screen views.
    var unfinished: [Todo] { ordered.filter { !$0.isDone } }

    init(todos: [Todo], referenceDate: Date, calendar: Calendar = .current) {
        let today = todos.filter { calendar.isDate($0.day, inSameDayAs: referenceDate) }
        ordered = today.filter { !$0.isDone } + today.filter(\.isDone)
        total = today.count
        doneCount = today.filter(\.isDone).count
    }

    private init(ordered: [Todo], total: Int, doneCount: Int) {
        self.ordered = ordered
        self.total = total
        self.doneCount = doneCount
    }

    /// A believable-looking day for the gallery preview and any moment the
    /// real file can't be read.
    static var demo: TodaySnapshot {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let todos = [
            Todo(text: "Ship the widget", day: today, group: "Work"),
            Todo(text: "Review the sync merge", day: today, group: "Work",
                 verdict: Verdict(status: .inProgress, evidence: "Open in the 2 PM session")),
            Todo(text: "Call the plumber", day: today, group: "Personal"),
            Todo(text: "Morning run", day: today, isDone: true),
        ]
        return TodaySnapshot(todos: todos, referenceDate: now)
    }

    /// The neutral loading placeholder the system shows before the first
    /// snapshot resolves — a calm, populated shape rather than an empty one.
    static var placeholder: TodaySnapshot { demo }

    /// A group's emoji badge, mirroring the app's built-in defaults. The widget
    /// only decodes `todos`, so user-customized badges fall back to the
    /// built-in map, then a neutral folder.
    static func emoji(forGroup group: String) -> String {
        let key = TodoGroupName.key(for: group)
        return TodoGroupName.defaultEmoji[key] ?? TodoGroupName.fallbackEmoji
    }
}

// MARK: - Timeline

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: TodaySnapshot
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        let now = Date()
        // The gallery preview (isPreview) always gets the polished demo day.
        let snapshot = context.isPreview
            ? .demo
            : (TodayStore.snapshot(for: now) ?? .demo)
        completion(TodayEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now

        var entries: [TodayEntry] = [
            TodayEntry(date: now, snapshot: TodayStore.snapshot(for: now) ?? .demo),
        ]

        // A second entry exactly at midnight recomputes "today" against the new
        // day so the widget flips even if the system defers the 15-minute
        // reload; a fresh read then supplies the new day's real todos.
        if nextMidnight > now {
            let midnightSnapshot = TodayStore.snapshot(for: nextMidnight) ?? .demo
            entries.append(TodayEntry(date: nextMidnight, snapshot: midnightSnapshot))
        }

        // Refresh a quarter-hour out so checked-off todos and new additions
        // surface without waiting for the day to turn over.
        let refresh = calendar.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}
