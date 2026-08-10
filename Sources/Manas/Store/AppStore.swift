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
    /// Shared groups, stored as the rows that go over the wire rather than as
    /// assembled models. Keeping the tombstone and the stamp in hand is what
    /// lets a share be created or revoked offline and still converge:
    /// `SharedGroupRecord`/`SharedGroupMemberRecord` are both the local store
    /// and the sync payload. `sharedGroups` assembles them for the UI.
    var sharedGroupRecords: [SharedGroupRecord] = [] { didSet { scheduleSave() } }
    var sharedMemberRecords: [SharedGroupMemberRecord] = [] { didSet { scheduleSave() } }
    /// The name this user shows up as in a shared group's avatars. Written
    /// onto their own membership rows so the other side sees it too.
    var myDisplayName: String? { didSet { scheduleSave() } }
    /// Sections the user has folded away, by stable key (see `SectionKey`).
    /// A view preference rather than data: it is deliberately not part of the
    /// synced todo record, so collapsing a group on the desktop doesn't reach
    /// across and fold it on the phone.
    var collapsedSections: Set<String> = [] { didSet { scheduleSave() } }
    var lastCheckedAt: Date? { didSet { scheduleSave() } }
    /// Start time of the latest automatic attempt, successful or not. This
    /// survives relaunches so an update, crash, or CLI failure cannot trigger
    /// another token-spending pass immediately.
    var lastAutomaticCheckAt: Date? { didSet { scheduleSave() } }
    var syncedSourceCount: Int = 0 { didSet { scheduleSave() } }

    /// The judge always runs Sonnet; there is no user-facing model choice.
    /// Not persisted — old state.json files carrying a `selectedModel` key
    /// still decode (unknown keys are ignored).
    let selectedModel: JudgeModel = .sonnet

    // MARK: - Transient check-in state (not persisted)

    /// The day sitting at the top of the feed's viewport. The header names it,
    /// so scrolling up into history retitles the window instead of leaving a
    /// static "Manas" over somebody else's Tuesday. Transient: it describes
    /// where the scroll is, which is not worth persisting.
    var visibleFeedDay: Date = Calendar.current.startOfDay(for: Date())

    /// The signed-in phone number as digits, pushed in by `SyncController`.
    /// It is who "you" are in a shared group: the author stamped onto new
    /// todos, and the member an avatar labels as yourself. Derived from the
    /// session rather than persisted, so signing out forgets it.
    var currentPhone: String?

    /// Who this device's address book thinks a member's number belongs to.
    /// The app-wide resolver by default; tests hand in one backed by a fake
    /// directory. A reference rather than a hard `ContactNames.shared` call so
    /// `memberLabel` stays testable — the naming rules are the part of this
    /// feature worth pinning down, and they cannot be exercised against the
    /// real Contacts framework.
    ///
    /// Deliberately not persisted and never written back: a resolved name is
    /// drawn and forgotten (see `ContactNames`).
    var contactNames: ContactNames = .shared

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
    /// Serializes state writes away from the UI actor. `saveNow()` uses the
    /// same queue synchronously, so a final quit-time snapshot always lands
    /// after any debounced write already in flight.
    @ObservationIgnored private let persistenceQueue = DispatchQueue(
        label: "dev.viraat.manas.state-persistence",
        qos: .utility
    )

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
            sharedGroupRecords = state.sharedGroupRecords ?? []
            sharedMemberRecords = state.sharedMemberRecords ?? []
            myDisplayName = state.myDisplayName
            collapsedSections = Self.pruningCollapsedSections(
                state.collapsedSections ?? [],
                toDaysWithTodos: state.todos
            )
            lastCheckedAt = state.lastCheckedAt
            lastAutomaticCheckAt = state.lastAutomaticCheckAt
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
        let base: URL
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = support
        } else {
            #if os(macOS)
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            #else
            base = FileManager.default.temporaryDirectory
            #endif
        }
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

    /// Every bucket a todo can be filed into, shared groups included. Shared
    /// ones come last so the private list a user already knows stays where it
    /// was, and each keeps its share id — the private "Manas" and the "Manas"
    /// someone shared are two separate destinations even here.
    var availableDestinations: [TodoDestination] {
        availableTodoGroups.map { TodoDestination(group: $0) }
            + sharedGroups.map { TodoDestination(group: $0.name, shareID: $0.id) }
    }

    /// Buckets that always show on today, even while empty: the built-ins, the
    /// user's own groups, and every shared group — a group somebody shared has
    /// to be visible before anything is in it, or there is nowhere to add.
    var standingDestinations: [TodoDestination] {
        standingGroups.map { TodoDestination(group: $0) }
            + sharedGroups.map { TodoDestination(group: $0.name, shareID: $0.id) }
    }

    /// Registers a user-created group so it appears as a bucket right away,
    /// before any todo is dropped into it. Returns the canonical label.
    @discardableResult
    func createGroup(_ rawValue: String, emoji: String? = nil) -> String? {
        guard let group = canonicalTodoGroup(rawValue) else { return nil }
        let key = TodoGroupName.key(for: group)
        let isNew = !standingGroups.contains(where: { TodoGroupName.key(for: $0) == key })
        if isNew {
            customGroups.append(group)
            UsageAnalytics.shared.capture(.groupCreated)
        }
        if emoji != nil { setGroupEmoji(group, emoji: emoji) }
        return group
    }

    /// Deletes a group: clears it from every todo, drops its emoji, and removes
    /// it from the created list. Built-in Work and Personal always remain
    /// available even after their todos are cleared.
    ///
    /// Todos in a shared group of the same name are left alone — the label is
    /// shorthand for a private bucket here, and a shared one is only ended by
    /// its owner stopping the share.
    func deleteGroup(_ group: String) {
        let key = TodoGroupName.key(for: group)
        for index in todos.indices
        where todos[index].shareID == nil
            && todos[index].group.map({ TodoGroupName.key(for: $0) }) == key {
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

    /// A shared group's badge travels with the share, so both people see the
    /// same icon; everything else falls back to the local choice.
    func emoji(for destination: TodoDestination) -> String {
        if let shareID = destination.shareID, let share = sharedGroup(id: shareID) {
            return share.emoji ?? TodoGroupName.fallbackEmoji
        }
        return destination.group.map { emoji(forGroup: $0) } ?? TodoGroupName.fallbackEmoji
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

    /// Removes all user-authored and derived state from this installation.
    /// Used after the server confirms account deletion.
    func resetUserData() {
        todos = []
        discoveredActivities = []
        usageRecords = []
        groupEmojis = [:]
        customGroups = []
        sharedGroupRecords = []
        sharedMemberRecords = []
        myDisplayName = nil
        collapsedSections = []
        lastCheckedAt = nil
        lastAutomaticCheckAt = nil
        syncedSourceCount = 0
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
        addTodo(text, on: day, destination: TodoDestination(group: group))
    }

    /// Adds a todo into a specific bucket, which may be a shared one. The
    /// author is stamped from the signed-in number so a shared list can say
    /// who put each line there.
    @discardableResult
    func addTodo(_ text: String, on day: Date = Date(), destination: TodoDestination) -> Todo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolved = resolve(destination)
        let todo = Todo(
            text: trimmed,
            day: day,
            group: resolved.group,
            shareID: resolved.shareID,
            authorPhone: currentPhone
        )
        insert(todo)
        UsageAnalytics.shared.capture(.todoCreated(
            day: UsageAnalytics.dayRelation(for: day),
            hasGroup: todo.group != nil
        ))
        if resolved.isShared { UsageAnalytics.shared.capture(.sharedTodoAdded) }
        return todo
    }

    /// Moves a todo into a group (or clears it with nil). Manual choices win:
    /// the judge only auto-groups todos that have no group yet, so this is
    /// never overwritten by a later check-in.
    func setTodoGroup(_ id: Todo.ID, group: String?) {
        setTodoGroup(id, to: TodoDestination(group: group))
    }

    /// Moves a todo between buckets, shared ones included. Moving *out* of a
    /// shared group drops its share id, which is what makes it private again;
    /// moving *in* adds it, which is what publishes it to the other members.
    func setTodoGroup(_ id: Todo.ID, to destination: TodoDestination) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        let resolved = resolve(destination)
        guard todos[index].destination != resolved else { return }
        // Somebody else's line in a shared group is theirs: check it off,
        // delete it, but don't re-file it. The server's row-level security
        // says the same, and one rejected row fails a whole sync batch — so
        // the move is refused here rather than left to blow up later.
        guard isAuthoredByCurrentUser(todos[index]) || resolved.shareID == todos[index].shareID
        else { return }
        todos[index].group = resolved.group
        todos[index].shareID = resolved.shareID
        // A todo written before sign-in has no author; moving it into a shared
        // group is the moment one is needed, so claim it here.
        if resolved.isShared, todos[index].authorPhone == nil {
            todos[index].authorPhone = currentPhone
        }
        UsageAnalytics.shared.capture(.todoGroupChanged(hasGroup: resolved.group != nil))
        if resolved.isShared { UsageAnalytics.shared.capture(.sharedTodoAdded) }
    }

    /// Canonicalizes a destination. A shared bucket always carries its share's
    /// current name, so renaming a share renames the label everywhere; a
    /// private one reuses an existing spelling of its label. A share id that no
    /// longer resolves (the owner stopped sharing) falls back to a plain group,
    /// which is exactly what should happen to its todos.
    func resolve(_ destination: TodoDestination) -> TodoDestination {
        if let shareID = destination.shareID, let share = sharedGroup(id: shareID) {
            return TodoDestination(group: share.name, shareID: shareID)
        }
        return TodoDestination(group: canonicalTodoGroup(destination.group))
    }

    /// New todos go on top of their day's group. A day's first todo lands at
    /// the front of the array — cross-day array order is irrelevant since
    /// the grouped accessors filter by day.
    private func insert(_ todo: Todo) {
        let calendar = Calendar.current
        let index = todos.firstIndex { calendar.isDate($0.day, inSameDayAs: todo.day) } ?? 0
        todos.insert(todo, at: index)
    }

    /// Reorders `id` within its own day and group so it sits immediately
    /// before (or after) `anchorID`. A no-op unless both todos share a day and
    /// group, so a reorder can never silently move a todo across buckets. The
    /// flat array's order within a day+group is the display order, so inserting
    /// the dragged todo adjacent to its anchor lands it in the right spot even
    /// when other groups' todos are interleaved between them.
    func moveTodo(_ id: Todo.ID, relativeTo anchorID: Todo.ID, after: Bool) {
        guard id != anchorID,
              let from = todos.firstIndex(where: { $0.id == id }),
              let anchor = todos.firstIndex(where: { $0.id == anchorID }),
              Calendar.current.isDate(todos[from].day, inSameDayAs: todos[anchor].day),
              todos[from].destination.key == todos[anchor].destination.key
        else { return }
        let moved = todos.remove(at: from)
        // The anchor's index may have shifted after the removal, so find it again.
        guard let landing = todos.firstIndex(where: { $0.id == anchorID }) else {
            todos.insert(moved, at: min(from, todos.count))
            return
        }
        todos.insert(moved, at: after ? landing + 1 : landing)
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
        let todo = todos[index]
        // Here rather than at the three places that call this — the checkbox,
        // the space bar, and the phone's tap — because a fourth way to finish
        // a todo should not have to remember to make a sound. `Sounds` is off
        // until an app switches it on, so this stays silent in tests.
        if todo.isDone { Sounds.pop() }
        let event: UsageAnalytics.Event = todo.isDone
            ? .todoCompleted(
                day: UsageAnalytics.dayRelation(for: todo.day),
                hasGroup: todo.group != nil
            )
            : .todoReopened(
                day: UsageAnalytics.dayRelation(for: todo.day),
                hasGroup: todo.group != nil
            )
        UsageAnalytics.shared.capture(event)
    }

    /// Accepting a "done" verdict also checks the todo off.
    func setVerdictAccepted(_ id: Todo.ID, accepted: Bool) {
        guard let index = todos.firstIndex(where: { $0.id == id }), todos[index].verdict != nil else { return }
        todos[index].verdict?.accepted = accepted
        if accepted, todos[index].verdict?.status == .done {
            todos[index].isDone = true
        }
    }

    /// Re-dates a todo onto a different calendar day, landing it on top of the
    /// destination day's list like a freshly added todo. Any verdict is cleared
    /// because it judged the todo against the old day's activity; moved onto
    /// today it will simply be re-judged. A no-op if the day doesn't change.
    func rescheduleTodo(_ id: Todo.ID, to day: Date) {
        let target = Calendar.current.startOfDay(for: day)
        guard let index = todos.firstIndex(where: { $0.id == id }),
              !Calendar.current.isDate(todos[index].day, inSameDayAs: target)
        else { return }
        var todo = todos.remove(at: index)
        todo.day = target
        todo.verdict = nil
        insert(todo)
        UsageAnalytics.shared.capture(.todoRescheduled(
            day: UsageAnalytics.dayRelation(for: target)
        ))
    }

    /// Rolls every unfinished todo from an earlier day onto today so nothing
    /// planned silently falls off the bottom of the feed. Each carried item is
    /// re-dated to today and its stale verdict cleared (it will be re-judged
    /// against today's activity), keeping its group. Finished past todos stay
    /// put as history, and today/future todos are untouched. Carried items lead
    /// today's list oldest-first, so the longest-lingering task sits on top.
    /// Returns how many were carried, so a caller can note the rollover.
    @discardableResult
    func carryForwardOverdueTodos(now: Date = Date()) -> Int {
        let today = Calendar.current.startOfDay(for: now)
        let overdueIndices = todos.indices.filter { !todos[$0].isDone && todos[$0].day < today }
        guard !overdueIndices.isEmpty else { return 0 }
        // Snapshot before removal, then drop from the back so earlier indices
        // stay valid.
        let carried = overdueIndices.map { todos[$0] }.sorted { $0.day < $1.day }
        for index in overdueIndices.reversed() { todos.remove(at: index) }
        // Front-insert newest-first so the oldest overdue ends up on top.
        for var todo in carried.reversed() {
            todo.day = today
            todo.verdict = nil
            insert(todo)
        }
        return carried.count
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
        UsageAnalytics.shared.capture(.todoRescheduled(day: .today))
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
    /// added items stay on top, with completed todos sunk to the bottom.
    /// Clusters on the todo's whole destination rather than on its label, so a
    /// shared "Manas" and a private "Manas" stay two separate buckets instead
    /// of pouring private work into a list somebody else can read.
    func todoGroups(on day: Date) -> [TodoGroup] {
        let dayTodos = todos(on: day)
        var order: [String] = []
        var byKey: [String: TodoGroup] = [:]
        for todo in dayTodos {
            let destination = todo.destination
            let key = destination.key
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = TodoGroup(
                    // A shared bucket is titled by its share, so the owner
                    // renaming it retitles it on every device at once.
                    group: destination.shareID.flatMap { sharedGroup(id: $0)?.name } ?? destination.group,
                    shareID: destination.shareID,
                    todos: []
                )
            }
            byKey[key]?.todos.append(todo)
        }
        // The unlabeled cluster leads the day; labeled groups follow in the
        // order their first todo appears.
        let ungroupedKey = TodoDestination.ungrouped.key
        return (order.filter { $0 == ungroupedKey } + order.filter { $0 != ungroupedKey })
            .compactMap { key in
                guard var group = byKey[key] else { return nil }
                group.todos = sinkingDone(group.todos)
                return group
            }
    }

    /// Finished todos drop below the unfinished ones so the live list stays
    /// short without losing the day's record. Partitioning (rather than a
    /// sort) keeps each half in its stored order, and because this is a
    /// display-only view over `todos`, the synced `position` of every row is
    /// untouched — a completion never rewrites the day's order for the
    /// other device.
    private func sinkingDone(_ todos: [Todo]) -> [Todo] {
        todos.filter { !$0.isDone } + todos.filter(\.isDone)
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

    // MARK: - Collapsible sections

    /// Whether a section is folded away. Unknown keys read as expanded, so a
    /// group collapsed and later deleted leaves nothing behind to clean up.
    func isCollapsed(_ key: String) -> Bool {
        collapsedSections.contains(key)
    }

    func toggleCollapsed(_ key: String) {
        if collapsedSections.contains(key) {
            collapsedSections.remove(key)
        } else {
            collapsedSections.insert(key)
        }
    }

    /// Folded-section keys worth keeping. Group keys are scoped to a day, so
    /// without this they would accumulate one entry per group per day forever;
    /// a day with no todos left has no headers to unfold either way. Also
    /// drops the dayless `group:` keys written by builds that folded a label
    /// across every day at once.
    static func pruningCollapsedSections(
        _ keys: some Sequence<String>,
        toDaysWithTodos todos: [Todo]
    ) -> Set<String> {
        let liveDays = Set(todos.map { SectionKey.dayKey($0.day) })
        return Set(keys.filter { key in
            guard !SectionKey.isStaleGroupKey(key) else { return false }
            guard let day = SectionKey.dayComponent(of: key) else { return true }
            return liveDays.contains(day)
        })
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
        // Observed work lands checked off, carrying its evidence as an accepted
        // verdict. A commitment lands open with no verdict — it is work the
        // user still owes, and filing it as done would tick off the very thing
        // it was surfaced to remind them about.
        let isDone = activity.kind == .done
        let todo = Todo(
            text: activity.title,
            group: activity.group,
            isDone: isDone,
            verdict: isDone
                ? Verdict(status: .done, evidence: activity.evidence, accepted: true)
                : nil
        )
        insert(todo)
        UsageAnalytics.shared.capture(.discoveredTodoAdded)
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
            // Auto-categorization fills in blanks only. A todo the user has
            // already filed — by dragging it, or by picking a group as they
            // typed it — keeps that group forever, because a check-in that
            // reshuffled hand-sorted todos every hour would be worse than no
            // grouping at all. Canonicalizing reuses an existing spelling so a
            // re-check can't fork "Manas" and "manas" into two piles.
            if todos[index].group == nil,
               let suggested = canonicalTodoGroup(result.groups[todos[index].id]),
               suggested != TodoGroupName.wasteOfTime {
                todos[index].group = suggested
            }
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

    fileprivate struct PersistedState: Codable, Sendable {
        var todos: [Todo]
        var discoveredActivities: [DiscoveredActivity]
        var usageRecords: [UsageRecord]
        var dailyTokenBudget: Int
        // Optional so state.json files written before these fields decode
        // cleanly instead of tripping the "start fresh" fallback.
        var groupEmojis: [String: String]?
        var customGroups: [String]?
        var sharedGroupRecords: [SharedGroupRecord]?
        var sharedMemberRecords: [SharedGroupMemberRecord]?
        var myDisplayName: String?
        /// Sorted on the way out so the file doesn't churn on every save from
        /// Set's unstable iteration order.
        var collapsedSections: [String]?
        var lastCheckedAt: Date?
        var lastAutomaticCheckAt: Date?
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
            sharedGroupRecords: sharedGroupRecords,
            sharedMemberRecords: sharedMemberRecords,
            myDisplayName: myDisplayName,
            collapsedSections: Self.pruningCollapsedSections(
                collapsedSections,
                toDaysWithTodos: todos
            ).sorted(),
            lastCheckedAt: lastCheckedAt,
            lastAutomaticCheckAt: lastAutomaticCheckAt,
            syncedSourceCount: syncedSourceCount
        )
    }

    /// Writes immediately, cancelling any pending debounced save. Call on
    /// termination or from tests; normal mutations save themselves.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = persistedState
        let url = fileURL
        let logger = logger
        persistenceQueue.sync {
            Self.write(snapshot, to: url, logger: logger)
        }
    }

    private func scheduleSave() {
        guard !suppressAutosave else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDebounce] in
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.persistedState
            let url = self.fileURL
            let logger = self.logger
            let queue = self.persistenceQueue
            await withCheckedContinuation { continuation in
                queue.async {
                    Self.write(snapshot, to: url, logger: logger)
                    continuation.resume()
                }
            }
        }
    }

    nonisolated private static func write(
        _ state: PersistedState,
        to url: URL,
        logger: Logger
    ) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try makeEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save state: \(error.localizedDescription)")
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
