#if DEBUG
import Foundation

/// Screenshot/preview seed. Only used by the `-manasPreviewSignedIn` launch
/// seam (see `RootView`), and only when the store is empty, so a simulator
/// capture can show a lived-in feed without a real cloud session. It writes a
/// handful of todos directly (verdicts and all) rather than through the store's
/// add helpers, which can't set verdicts.
@MainActor
enum DemoSeed {
    static func seedIfEmpty(_ store: AppStore) {
        guard store.todos.isEmpty else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        // Array order is display order within a day+group (newest on top).
        store.todos = [
            // Today · ungrouped cluster leads.
            Todo(text: "Water the plants", day: today),
            // Today · Work.
            Todo(
                text: "Ship the iOS sign-in flow",
                day: today,
                group: "Work",
                verdict: Verdict(status: .inProgress, evidence: "Active in the 2:14 PM claude session.")
            ),
            Todo(
                text: "Review Alex's pull request",
                day: today,
                group: "Work",
                isDone: true,
                verdict: Verdict(status: .done, evidence: "Approved PR #128 at 11:40 AM.", accepted: true)
            ),
            // Today · Personal.
            Todo(text: "Book a dentist appointment", day: today, group: "Personal"),
            // Yesterday · one thing left unfinished, receding above Today.
            Todo(text: "Draft the Q3 roadmap", day: yesterday, group: "Work"),
            // Tomorrow · a plan ahead.
            Todo(text: "Prep for the team standup", day: tomorrow, group: "Work"),
        ]
    }
}
#endif
