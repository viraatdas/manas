import Foundation
import Observation
import os

/// Single source of truth for the app. Every persisted property schedules a
/// debounced atomic JSON save on mutation (including in-place element
/// mutation, since arrays are value types), so callers can mutate state
/// directly or through the helpers — both persist.
@MainActor
@Observable
final class AppStore {
    // MARK: - Persisted state

    var todos: [Todo] = [] { didSet { scheduleSave() } }
    var discoveredActivities: [DiscoveredActivity] = [] { didSet { scheduleSave() } }
    var usageRecords: [UsageRecord] = [] { didSet { scheduleSave() } }
    /// Soft daily token budget backing the usage strip's dots — visual, not a limit.
    var dailyTokenBudget: Int = 10_000 { didSet { scheduleSave() } }
    /// User-chosen emoji per group, keyed by the group's case-folded key.
    /// Built-in groups fall back to a default when absent (see `emoji(forGroup:)`).
    var groupEmojis: [String: String] = [:] { didSet { scheduleSave() } }
    /// Groups the user created, in creation order. Kept even while empty so a
    /// new group shows up as a standing bucket the moment it's made.
    var customGroups: [String] = [] { didSet { scheduleSave() } }
    var lastCheckedAt: Date? { didSet { scheduleSave() } }
    var syncedSourceCount: Int = 0 { didSet { scheduleSave() } }

    /// The judge always runs Sonnet; there is no user-facing model choice.
    /// Not persisted — old state.json files carrying a `selectedModel` key
    /// still decode (unknown keys are ignored).
    let selectedModel: JudgeModel = .sonnet

    // MARK: - Transient check-in state (not persisted)

    /// True while a check-in is running — spins the header refresh button
    /// and blocks overlapping checks.
    var isCheckingIn = false
    /// True while onboarding is probing local source access without invoking
    /// the judge. Kept separate so first launch can verify permissions before
    /// spending any Claude tokens.
    var isRefreshingSourceHealth = false
    /// The last check-in's failure, sentence-case and UI-ready; nil once a
    /// check starts or succeeds.
    var lastCheckInError: String?
    /// Coding-agent sessions observed in the latest check-in, for the usage
    /// panel's "Coding sessions today" card. Transient and refreshed on every
    /// check-in (auto or manual); ranked by tokens spent. These are the coding
    /// agents' own subscription tokens, kept apart from Manas's check-in cost.
    var codingSessionsToday: [CodingSessionSummary] = []
    /// Per-source health for the current app session. Raw source activity is
    /// deliberately not persisted; only derived todo evidence is saved.
    var sourceStatuses: [ActivitySourceStatus] = [
        .waiting(.claude),
        .waiting(.codex),
        .waiting(.arc),
        .waiting(.screenTime),
        .waiting(.messages),
    ]

    @ObservationIgnored var autoCheckTask: Task<Void, Never>?
    @ObservationIgnored var checkInTask: Task<Void, Never>?

    // MARK: - Setup

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let saveDebounce: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var suppressAutosave = true
    @ObservationIgnored private let logger = Logger(subsystem: "Manas", category: "AppStore")

    /// - Parameters:
    ///   - fileURL: Override for tests; defaults to
    ///     `~/Library/Application Support/Manas/state.json`.
    ///   - saveDebounce: How long to coalesce mutations before writing.
    init(fileURL: URL? = nil, saveDebounce: Duration = .milliseconds(500)) {
        self.fileURL = fileURL ?? Self.defaultStateURL
        self.saveDebounce = saveDebounce
        if let state = Self.loadState(from: self.fileURL, logger: logger) {
            todos = state.todos
            discoveredActivities = state.discoveredActivities
            usageRecords = state.usageRecords
            dailyTokenBudget = state.dailyTokenBudget
            groupEmojis = state.groupEmojis ?? [:]
            customGroups = state.customGroups ?? []
            lastCheckedAt = state.lastCheckedAt
            syncedSourceCount = state.syncedSourceCount
        }
        suppressAutosave = false
    }

    static var defaultStateURL: URL {
        // Dev/verification seam: point a launched app at a scratch state
        // file so screenshot runs never read or write the real one.
        if let override = ProcessInfo.processInfo.environment["MANAS_STATE_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Manas/state.json")
    }

    // MARK: - Todos

    /// The distinct group labels currently in use across all days, in
    /// first-appearance order — the stable set the judge is asked to reuse so
    /// clusters don't churn between hourly re-checks.
    var groupNamesInUse: [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for todo in todos {
            guard let group = todo.group else { continue }
            if seen.insert(TodoGroupName.key(for: group)).inserted {
                labels.append(group)
            }
        }
        return labels
    }

    static let suggestedTodoGroups = TodoGroupName.suggestions

    /// The groups that always show as standing buckets on today: the built-in
    /// Work and Personal, plus every group the user created (even empty ones).
    var standingGroups: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for label in Self.suggestedTodoGroups + customGroups
        where seen.insert(TodoGroupName.key(for: label)).inserted {
            result.append(label)
        }
        return result
    }

    /// Groups offered in the picker: the standing groups first (Work, Personal,
    /// then created groups), then any other group already used by a todo.
    var availableTodoGroups: [String] {
        var seen = Set(standingGroups.map { TodoGroupName.key(for: $0) })
        let extra = groupNamesInUse.filter { seen.insert(TodoGroupName.key(for: $0)).inserted }
        return standingGroups + extra
    }

    /// Registers a user-created group so it appears as a bucket right away,
    /// before any todo is dropped into it. Returns the canonical label.
    @discardableResult
    func createGroup(_ rawValue: String, emoji: String? = nil) -> String? {
        guard let group = canonicalTodoGroup(rawValue) else { return nil }
        let key = TodoGroupName.key(for: group)
        if !standingGroups.contains(where: { TodoGroupName.key(for: $0) == key }) {
            customGroups.append(group)
        }
        if emoji != nil { setGroupEmoji(group, emoji: emoji) }
        return group
    }

    /// Deletes a group: clears it from every todo, drops its emoji, and removes
    /// it from the created list. Built-in Work and Personal always remain
    /// available even after their todos are cleared.
    func deleteGroup(_ group: String) {
        let key = TodoGroupName.key(for: group)
        for index in todos.indices where todos[index].group.map({ TodoGroupName.key(for: $0) }) == key {
            todos[index].group = nil
        }
        customGroups.removeAll { TodoGroupName.key(for: $0) == key }
        groupEmojis[key] = nil
    }

    /// The emoji badge for a group: the user's choice, else a built-in default,
    /// else a neutral folder.
    func emoji(forGroup group: String) -> String {
        let key = TodoGroupName.key(for: group)
        return groupEmojis[key] ?? TodoGroupName.defaultEmoji[key] ?? TodoGroupName.fallbackEmoji
    }

    /// Assigns (or clears) a group's emoji. Stored by the group's key so every
    /// todo in that group shows the same badge.
    func setGroupEmoji(_ group: String, emoji: String?) {
        guard let canonical = canonicalTodoGroup(group) else { return }
        let key = TodoGroupName.key(for: canonical)
        if let emoji = TodoGroupName.normalizedEmoji(emoji) {
            groupEmojis[key] = emoji
        } else {
            groupEmojis[key] = nil
        }
    }

    /// Canonicalizes an incoming group label, reusing an existing spelling
    /// when the same theme comes back with different case or spacing so a
    /// re-check never forks "Manas" and "manas" into two clusters.
    func canonicalTodoGroup(_ rawValue: String?) -> String? {
        guard let normalized = TodoGroupName.normalized(rawValue) else { return nil }
        let key = TodoGroupName.key(for: normalized)
        return availableTodoGroups.first { TodoGroupName.key(for: $0) == key } ?? normalized
    }

    @discardableResult
    func addTodo(_ text: String, on day: Date = Date(), group: String? = nil) -> Todo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let todo = Todo(text: trimmed, day: day, group: canonicalTodoGroup(group))
        insert(todo)
        return todo
    }

    /// Moves a todo into a group (or clears it with nil). Manual choices win:
    /// the judge only auto-groups todos that have no group yet, so this is
    /// never overwritten by a later check-in.
    func setTodoGroup(_ id: Todo.ID, group: String?) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].group = canonicalTodoGroup(group)
    }

    /// New todos go on top of their day's group. A day's first todo lands at
    /// the front of the array — cross-day array order is irrelevant since
    /// the grouped accessors filter by day.
    private func insert(_ todo: Todo) {
        let calendar = Calendar.current
        let index = todos.firstIndex { calendar.isDate($0.day, inSameDayAs: todo.day) } ?? 0
        todos.insert(todo, at: index)
    }

    func removeTodo(_ id: Todo.ID) {
        todos.removeAll { $0.id == id }
    }

    /// Replaces a todo's text with an edited version. Whitespace is trimmed;
    /// an empty result is rejected so a todo can't be blanked out by accident
    /// (delete is the way to remove one). Returns whether the edit was applied.
    @discardableResult
    func editTodoText(_ id: Todo.ID, to newText: String) -> Bool {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = todos.firstIndex(where: { $0.id == id }),
              todos[index].text != trimmed
        else { return false }
        todos[index].text = trimmed
        return true
    }

    func toggleDone(_ id: Todo.ID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].isDone.toggle()
    }

    /// Accepting a "done" verdict also checks the todo off.
    func setVerdictAccepted(_ id: Todo.ID, accepted: Bool) {
        guard let index = todos.firstIndex(where: { $0.id == id }), todos[index].verdict != nil else { return }
        todos[index].verdict?.accepted = accepted
        if accepted, todos[index].verdict?.status == .done {
            todos[index].isDone = true
        }
    }

    /// Brings an unfinished past todo forward to the top of today. It will
    /// be re-judged fresh against today's activity, so the stale verdict is
    /// cleared. Finished todos and today/future todos are left alone.
    func moveToToday(_ id: Todo.ID) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let index = todos.firstIndex(where: { $0.id == id }),
              !todos[index].isDone,
              todos[index].day < today
        else { return }
        var todo = todos.remove(at: index)
        todo.day = today
        todo.verdict = nil
        insert(todo)
    }

    // MARK: - Day groups

    /// The todos belonging to the same calendar day as `day`, in list order.
    func todos(on day: Date) -> [Todo] {
        let calendar = Calendar.current
        return todos.filter { calendar.isDate($0.day, inSameDayAs: day) }
    }

    var todosToday: [Todo] { todos(on: Date()) }

    /// One day's todos clustered by the judge's automatic group: the unlabeled
    /// cluster of ungrouped todos leads, then each labeled group in the order
    /// its first todo appears. Each group keeps the day's todo order so newly
    /// added items stay on top.
    func todoGroups(on day: Date) -> [TodoGroup] {
        let dayTodos = todos(on: day)
        var groups: [TodoGroup] = []

        let ungrouped = dayTodos.filter { $0.group == nil }
        if !ungrouped.isEmpty {
            groups.append(TodoGroup(group: nil, todos: ungrouped))
        }

        var order: [String] = []
        var byKey: [String: (label: String, todos: [Todo])] = [:]
        for todo in dayTodos {
            guard let group = todo.group else { continue }
            let key = TodoGroupName.key(for: group)
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = (label: group, todos: [])
            }
            byKey[key]?.todos.append(todo)
        }
        for key in order {
            guard let entry = byKey[key] else { continue }
            groups.append(TodoGroup(group: entry.label, todos: entry.todos))
        }
        return groups
    }

    /// Days before today that have todos, newest first — read-only history.
    var pastDays: [DayGroup] {
        let today = Calendar.current.startOfDay(for: Date())
        return dayGroups { $0 < today }.sorted { $0.day > $1.day }
    }

    /// Days after today that have todos, soonest first — planned-ahead work.
    var upcomingDays: [DayGroup] {
        let today = Calendar.current.startOfDay(for: Date())
        return dayGroups { $0 > today }.sorted { $0.day < $1.day }
    }

    /// Groups the todos whose day satisfies `matching`. `Todo.day` is always
    /// start-of-day, so it is the group key as-is.
    private func dayGroups(matching: (Date) -> Bool) -> [DayGroup] {
        Dictionary(grouping: todos.filter { matching($0.day) }, by: \.day)
            .map { DayGroup(day: $0.key, todos: $0.value) }
    }

    // MARK: - Discovered activities

    func dismissDiscovered(_ id: DiscoveredActivity.ID) {
        guard let index = discoveredActivities.firstIndex(where: { $0.id == id }) else { return }
        discoveredActivities[index].resolution = .dismissed
    }

    /// Promotes a discovered activity into the todo list. It's something the
    /// user already did, so the todo arrives checked off with a done verdict
    /// carrying the evidence.
    @discardableResult
    func addDiscoveredToTodos(_ id: DiscoveredActivity.ID) -> Todo? {
        guard let index = discoveredActivities.firstIndex(where: { $0.id == id }),
              discoveredActivities[index].resolution == .pending
        else { return nil }
        discoveredActivities[index].resolution = .added
        let activity = discoveredActivities[index]
        // Discoveries are work observed today, so the todo lands on today and
        // inherits the judge's group so it clusters with its related work.
        let todo = Todo(
            text: activity.title,
            group: activity.group,
            isDone: true,
            verdict: Verdict(status: .done, evidence: activity.evidence, accepted: true)
        )
        insert(todo)
        return todo
    }

    // MARK: - Judge results

    /// Applies one judge pass: verdicts onto matching todos, the refreshed
    /// discovery list, and the usage record for the cost strip.
    func applyJudgeResult(_ result: JudgeResult) {
        let calendar = Calendar.current
        for index in todos.indices {
            // Only today is ever judged: past days are frozen history and
            // future days haven't happened yet, so neither can receive a
            // verdict even if the judge echoes back a stale id.
            guard calendar.isDateInToday(todos[index].day) else { continue }
            if var verdict = result.verdicts[todos[index].id] {
                // Re-checks run automatically all day; a verdict the user
                // already accepted stays settled unless the judge's call
                // actually changed. Evidence still refreshes.
                if let existing = todos[index].verdict,
                   existing.accepted == true, existing.status == verdict.status {
                    verdict.accepted = true
                }
                todos[index].verdict = verdict
            }
            // Grouping is manual for now (Work / Personal, dragged by the
            // user), so judge-suggested groups are intentionally not applied.
        }
        // Every pass re-observes the whole day, so its discoveries supersede
        // the previous pass's pending ones — keeping them would pile up a
        // rephrased duplicate of the same work every hour. Items the user
        // added or dismissed are kept forever so they never come back.
        let settled = discoveredActivities.filter { $0.resolution != .pending }
        var knownTitles = Set(todos.map { Self.dedupeKey($0.text) })
        knownTitles.formUnion(settled.map { Self.dedupeKey($0.title) })
        let fresh = result.discovered.filter { item in
            let key = Self.dedupeKey(item.title)
            return !key.isEmpty && knownTitles.insert(key).inserted
        }
        // Detected time sinks don't wait for a manual Add: they land straight
        // in the Waste of time bucket as checked-off entries. Their discovery
        // records settle as .added, so deleting the todo isn't undone by the
        // next pass re-discovering the same scrolling.
        discoveredActivities = settled + fresh.map { item in
            guard Self.isWasteOfTime(item.group) else { return item }
            var item = item
            item.resolution = .added
            insert(Todo(
                text: item.title,
                group: TodoGroupName.wasteOfTime,
                isDone: true,
                verdict: Verdict(status: .done, evidence: item.evidence, accepted: true)
            ))
            return item
        }
        usageRecords.append(result.usage)
        lastCheckedAt = result.usage.timestamp
    }

    /// True when the judge tagged a discovery with the built-in time-sink
    /// group, matched case-insensitively so a lowercased echo still counts.
    private static func isWasteOfTime(_ group: String?) -> Bool {
        guard let group else { return false }
        return TodoGroupName.key(for: group) == TodoGroupName.key(for: TodoGroupName.wasteOfTime)
    }

    private static func dedupeKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Usage aggregates

    func records(on date: Date) -> [UsageRecord] {
        let calendar = Calendar.current
        return usageRecords.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }
    }

    var recordsToday: [UsageRecord] { records(on: Date()) }
    var tokensUsedToday: Int { recordsToday.reduce(0) { $0 + $1.totalTokens } }
    var costTodayUSD: Double { recordsToday.reduce(0) { $0 + $1.costUSD } }
    var checkCountToday: Int { recordsToday.count }

    /// Every day that has at least one check-in, oldest first.
    var checkInDays: [CheckInDay] {
        let calendar = Calendar.current
        return Dictionary(grouping: usageRecords) { calendar.startOfDay(for: $0.timestamp) }
            .map { CheckInDay(date: $0.key, records: $0.value.sorted { $0.timestamp < $1.timestamp }) }
            .sorted { $0.date < $1.date }
    }

    /// A contiguous run of days ending on `end` (today by default), with
    /// empty days filled in — ready for the 7-day sparkline.
    func recentDays(_ count: Int = 7, endingOn end: Date = Date()) -> [CheckInDay] {
        let calendar = Calendar.current
        let endDay = calendar.startOfDay(for: end)
        let byDay = Dictionary(grouping: usageRecords) { calendar.startOfDay(for: $0.timestamp) }
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endDay) else { return nil }
            let records = (byDay[day] ?? []).sorted { $0.timestamp < $1.timestamp }
            return CheckInDay(date: day, records: records)
        }
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var todos: [Todo]
        var discoveredActivities: [DiscoveredActivity]
        var usageRecords: [UsageRecord]
        var dailyTokenBudget: Int
        // Optional so state.json files written before these fields decode
        // cleanly instead of tripping the "start fresh" fallback.
        var groupEmojis: [String: String]?
        var customGroups: [String]?
        var lastCheckedAt: Date?
        var syncedSourceCount: Int
    }

    private var persistedState: PersistedState {
        PersistedState(
            todos: todos,
            discoveredActivities: discoveredActivities,
            usageRecords: usageRecords,
            dailyTokenBudget: dailyTokenBudget,
            groupEmojis: groupEmojis,
            customGroups: customGroups,
            lastCheckedAt: lastCheckedAt,
            syncedSourceCount: syncedSourceCount
        )
    }

    /// Writes immediately, cancelling any pending debounced save. Call on
    /// termination or from tests; normal mutations save themselves.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.makeEncoder().encode(persistedState)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save state: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        guard !suppressAutosave else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDebounce] in
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private static func loadState(from url: URL, logger: Logger) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try makeDecoder().decode(PersistedState.self, from: data)
        } catch {
            logger.error("Failed to decode state, starting fresh: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
