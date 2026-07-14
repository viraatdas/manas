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
}

/// Fans out to all activity sources concurrently and merges their results,
/// tolerating per-source failure: one broken source never hides the others.
struct ActivityAggregator: Sendable {
    var sources: [any ActivitySource]

    init(sources: [any ActivitySource]) {
        self.sources = sources
    }

    /// The app's default lineup: Claude Code and Codex transcripts.
    static var standard: ActivityAggregator {
        ActivityAggregator(sources: [ClaudeCodeSource(), CodexSource()])
    }

    func fetchActivities(for date: Date) async -> AggregatedActivities {
        await withTaskGroup(of: (name: String, result: Result<[WorkActivity], any Error>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return (source.name, .success(try await source.fetchActivities(for: date)))
                    } catch {
                        return (source.name, .failure(error))
                    }
                }
            }

            var aggregated = AggregatedActivities()
            for await (name, result) in group {
                switch result {
                case .success(let activities):
                    aggregated.activities += activities
                    aggregated.syncedSourceCount += 1
                case .failure:
                    aggregated.failedSourceNames.append(name)
                }
            }
            // Task completion order is nondeterministic; sort for stable output.
            aggregated.activities.sort {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.summary < $1.summary
            }
            aggregated.failedSourceNames.sort()
            return aggregated
        }
    }
}
