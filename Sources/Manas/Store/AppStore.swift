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
    var selectedModel: JudgeModel = .haiku { didSet { scheduleSave() } }
    /// Soft daily token budget backing the usage strip's dots — visual, not a limit.
    var dailyTokenBudget: Int = 10_000 { didSet { scheduleSave() } }
    var lastCheckedAt: Date? { didSet { scheduleSave() } }
    var syncedSourceCount: Int = 0 { didSet { scheduleSave() } }

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
            selectedModel = state.selectedModel
            dailyTokenBudget = state.dailyTokenBudget
            lastCheckedAt = state.lastCheckedAt
            syncedSourceCount = state.syncedSourceCount
        }
        suppressAutosave = false
    }

    static var defaultStateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Manas/state.json")
    }

    // MARK: - Todos

    @discardableResult
    func addTodo(_ text: String) -> Todo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let todo = Todo(text: trimmed)
        todos.insert(todo, at: 0)
        return todo
    }

    func removeTodo(_ id: Todo.ID) {
        todos.removeAll { $0.id == id }
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
        let todo = Todo(
            text: activity.title,
            isDone: true,
            verdict: Verdict(status: .done, evidence: activity.evidence, accepted: true)
        )
        todos.insert(todo, at: 0)
        return todo
    }

    // MARK: - Judge results

    /// Applies one judge pass: verdicts onto matching todos, new discoveries
    /// (deduplicated by title so dismissed items don't reappear), and the
    /// usage record for the cost strip.
    func applyJudgeResult(_ result: JudgeResult) {
        for index in todos.indices {
            if let verdict = result.verdicts[todos[index].id] {
                todos[index].verdict = verdict
            }
        }
        let knownTitles = Set(discoveredActivities.map { $0.title.lowercased() })
        discoveredActivities.append(contentsOf: result.discovered.filter {
            !knownTitles.contains($0.title.lowercased())
        })
        usageRecords.append(result.usage)
        lastCheckedAt = result.usage.timestamp
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
        var selectedModel: JudgeModel
        var dailyTokenBudget: Int
        var lastCheckedAt: Date?
        var syncedSourceCount: Int
    }

    private var persistedState: PersistedState {
        PersistedState(
            todos: todos,
            discoveredActivities: discoveredActivities,
            usageRecords: usageRecords,
            selectedModel: selectedModel,
            dailyTokenBudget: dailyTokenBudget,
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
