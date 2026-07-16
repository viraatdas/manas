import Foundation

// The check-in engine. Checks run automatically — once at launch, then
// periodically — plus on demand from the header's refresh button. There is
// no "run" button; the header metadata row and usage strip are the feedback
// that checks are happening.
extension AppStore {
    /// A real day of transcripts makes a large prompt; the CLI's default 60s
    /// is too tight for haiku to chew through it (observed live).
    static let judgeTimeout: TimeInterval = 180

    /// How often the background check-in re-runs.
    static let autoCheckInterval: Duration = .seconds(3600)

    /// Starts the automatic cadence: one check right away, then one every
    /// `interval` for as long as the app runs. Idempotent.
    func startAutoCheckIns(
        every interval: Duration = AppStore.autoCheckInterval,
        aggregator: ActivityAggregator = .standard,
        judge: (any TodoJudge)? = nil
    ) {
        guard autoCheckTask == nil else { return }
        autoCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                if let running = self?.beginCheckIn(aggregator: aggregator, judge: judge) {
                    await running.value
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopAutoCheckIns() {
        autoCheckTask?.cancel()
        autoCheckTask = nil
        checkInTask?.cancel()
        checkInTask = nil
    }

    /// One manual check-in (the header refresh button). Ignored while a
    /// check is already running.
    func checkInNow(
        aggregator: ActivityAggregator = .standard,
        judge: (any TodoJudge)? = nil
    ) {
        _ = beginCheckIn(aggregator: aggregator, judge: judge)
    }

    /// Starts a check-in unless one is running; returns the task so the
    /// auto-cadence can await completion before sleeping.
    @discardableResult
    private func beginCheckIn(
        aggregator: ActivityAggregator,
        judge: (any TodoJudge)?
    ) -> Task<Void, Never>? {
        guard !isCheckingIn else { return nil }
        isCheckingIn = true
        lastCheckInError = nil
        let task = Task { [weak self] in
            do {
                try await self?.judgeToday(
                    aggregator: aggregator,
                    judge: judge ?? ClaudeCLIJudge(timeout: Self.judgeTimeout)
                )
            } catch is CancellationError {
                // App is quitting or the check was superseded; stay quiet.
            } catch {
                self?.lastCheckInError = error.localizedDescription
            }
            self?.isCheckingIn = false
        }
        checkInTask = task
        return task
    }

    /// One full check-in pass: gather today's activity from every source,
    /// judge the todos against it, then fold verdicts, discoveries, and the
    /// usage record into the store. Async and cancellable; every store
    /// mutation happens on the main actor while the heavy work (transcript
    /// parsing, the CLI subprocess) runs off it.
    func judgeToday(
        aggregator: ActivityAggregator = .standard,
        judge: any TodoJudge = ClaudeCLIJudge(timeout: AppStore.judgeTimeout)
    ) async throws {
        let aggregated = await aggregator.fetchActivities(for: Date())
        // Recorded even if judging below fails — the metadata row reports
        // ingestion, not judgment.
        syncedSourceCount = aggregated.syncedSourceCount
        try Task.checkCancellation()
        // Only today is judged: past days are frozen and future days are
        // plans, so neither belongs in the prompt.
        let todosToday = self.todosToday
        // A completely empty day (no todos today, nothing observed) isn't
        // worth a CLI call — and auto-checks would otherwise pile up
        // zero-token records. Mark the check and stop.
        guard !todosToday.isEmpty || !aggregated.activities.isEmpty else {
            lastCheckedAt = Date()
            return
        }
        let result = try await judge.judge(
            todos: todosToday,
            activities: aggregated.activities,
            model: selectedModel.rawValue
        )
        try Task.checkCancellation()
        applyJudgeResult(result)
    }
}
