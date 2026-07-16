import Foundation

/// The merged result of one sync pass across every registered source.
struct AggregatedActivities: Hashable, Sendable {
    /// All activities from every source that succeeded, sorted by start time.
    var activities: [WorkActivity] = []
    /// How many sources synced without error (an empty result still counts —
    /// "no Codex sessions today" is a successful sync).
    var syncedSourceCount: Int = 0
    /// Names of sources whose fetch threw, for the metadata row / diagnostics.
    var failedSourceNames: [String] = []
    /// One explicit result per configured source, stable-sorted for UI.
    var sourceStatuses: [ActivitySourceStatus] = []
}

/// Fans out to all activity sources concurrently and merges their results,
/// tolerating per-source failure: one broken source never hides the others.
struct ActivityAggregator: Sendable {
    var sources: [any ActivitySource]

    init(sources: [any ActivitySource]) {
        self.sources = sources
    }

    /// The app's local activity lineup. Every source is isolated: protected
    /// Messages or Screen Time access never prevents coding activity syncing.
    static var standard: ActivityAggregator {
        ActivityAggregator(sources: [
            ClaudeCodeSource(),
            CodexSource(),
            ArcHistorySource(),
            ScreenTimeSource(),
            MessagesSource(),
        ])
    }

    func fetchActivities(for date: Date) async -> AggregatedActivities {
        await withTaskGroup(
            of: (source: WorkSource, name: String, result: Result<[WorkActivity], any Error>).self
        ) { group in
            for source in sources {
                group.addTask {
                    do {
                        return (source.source, source.name, .success(try await source.fetchActivities(for: date)))
                    } catch {
                        return (source.source, source.name, .failure(error))
                    }
                }
            }

            var aggregated = AggregatedActivities()
            for await (source, name, result) in group {
                switch result {
                case .success(let activities):
                    aggregated.activities += activities
                    aggregated.syncedSourceCount += 1
                    aggregated.sourceStatuses.append(ActivitySourceStatus(
                        source: source,
                        state: .ready,
                        activityCount: activities.count
                    ))
                case .failure(let error):
                    aggregated.failedSourceNames.append(name)
                    let failure = error as? ActivitySourceFailure
                    aggregated.sourceStatuses.append(ActivitySourceStatus(
                        source: source,
                        state: failure?.statusState ?? .failed,
                        activityCount: 0,
                        detail: failure?.localizedDescription ?? error.localizedDescription
                    ))
                }
            }
            // Task completion order is nondeterministic; sort for stable output.
            aggregated.activities.sort {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.summary < $1.summary
            }
            aggregated.failedSourceNames.sort()
            aggregated.sourceStatuses.sort { $0.source.displayName < $1.source.displayName }
            return aggregated
        }
    }
}
