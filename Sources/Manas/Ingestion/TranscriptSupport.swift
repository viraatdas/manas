import Foundation

/// Half-open interval covering one calendar day. Sources use it both to pick
/// which transcript files are worth opening and to filter individual entries.
struct DayWindow: Sendable {
    let start: Date
    let end: Date

    init(containing date: Date, calendar: Calendar) {
        let start = calendar.startOfDay(for: date)
        self.start = start
        self.end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// Whether a file's lifetime could overlap the day: created before the day
    /// ended and last written after it started. Missing attributes err on the
    /// side of reading the file.
    func mayOverlap(created: Date?, modified: Date?) -> Bool {
        if let created, created >= end { return false }
        if let modified, modified < start { return false }
        return true
    }
}

/// Defensive helpers for the loosely-schema'd JSONL transcript formats.
/// Every accessor returns nil instead of trapping; unparseable lines are
/// simply skipped by callers.
enum TranscriptJSON {
    /// Longest JSON line we're willing to parse (tool results can embed whole
    /// files; anything bigger than this is not a line we can learn from).
    private static let maxLineBytes = 4_000_000

    static func object(fromLine line: some StringProtocol) -> [String: Any]? {
        guard line.utf8.count < maxLineBytes else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

/// Directory listing shared by both sources: direct-child .jsonl files whose
/// on-disk dates could overlap the requested day. Returns [] when the
/// directory doesn't exist.
enum TranscriptFiles {
    static func jsonlFiles(in directory: URL, overlapping window: DayWindow, limit: Int = 400) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for url in children where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile ?? false,
                  window.mayOverlap(created: values.creationDate, modified: values.contentModificationDate)
            else { continue }
            result.append(url)
            if result.count >= limit { break }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// What one session file contributed to the day: where it ran, when, what the
/// user asked for, what the assistant said it did, and what it cost.
struct SessionDigest: Sendable {
    private static let maxUserTexts = 60
    private static let maxSummaries = 12

    var projectPath: String?
    var startedAt: Date?
    var endedAt: Date?
    var userTexts: [String] = []
    var assistantSummaries: [String] = []
    var totalTokens = 0
    private var seenTextKeys: Set<String> = []
    private var bankedCumulativeTokens = 0
    private var lastCumulativeTokens = 0

    var hasActivity: Bool { startedAt != nil }

    mutating func observe(_ date: Date) {
        if startedAt.map({ date < $0 }) ?? true { startedAt = date }
        if endedAt.map({ date > $0 }) ?? true { endedAt = date }
    }

    /// Records a user prompt, deduplicating repeats (newer Codex rollouts
    /// carry the same text as both an event and a response item).
    mutating func addUserText(_ text: String) {
        guard userTexts.count < Self.maxUserTexts else { return }
        guard seenTextKeys.insert(String(text.prefix(240))).inserted else { return }
        userTexts.append(text)
    }

    mutating func addSummary(_ text: String) {
        guard assistantSummaries.count < Self.maxSummaries else { return }
        assistantSummaries.append(text)
    }

    /// Folds one cumulative session token total (Codex's `token_count`
    /// snapshots). Totals only grow within a conversation segment, but
    /// context compaction starts a fresh segment whose totals restart low —
    /// so a drop banks the finished segment instead of discarding it, and
    /// `totalTokens` counts every segment of a multi-compaction session.
    mutating func recordCumulativeTokens(_ total: Int) {
        if total < lastCumulativeTokens {
            bankedCumulativeTokens += lastCumulativeTokens
        }
        lastCumulativeTokens = total
        totalTokens = bankedCumulativeTokens + lastCumulativeTokens
    }
}

/// Turns raw transcript texts into the short human phrases that populate
/// `WorkActivity.features` ("implemented usage sparkline in Manas"-level).
enum FeatureExtraction {
    /// Replies that carry no information about what was worked on.
    private static let noise: Set<String> = [
        "ok", "okay", "yes", "yep", "no", "nope", "sure", "continue", "proceed",
        "go ahead", "do it", "thanks", "thank you", "test", "testing", "hello",
        "next", "done", "lgtm", "looks good", "try again", "retry", "keep going",
        "sounds good", "perfect", "great", "nice", "cool", "please continue",
    ]

    private static let labelPrefixes = ["objective:", "task:", "goal:", "todo:", "feature:", "fix:"]

    /// First meaningful line of a prompt or summary, cleaned up into a short
    /// phrase, or nil when the text is machine noise (tool markup, command
    /// wrappers, one-word acknowledgements).
    static func phrase(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard var line = trimmed
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        // Markdown links keep their visible text; then anything still starting
        // with markup ("<command-name>", "[Request interrupted…]") is noise.
        line = line.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        guard !line.hasPrefix("<"), !line.hasPrefix("[") else { return nil }

        // A bare URL or a slash command says nothing about what was built.
        guard !line.hasPrefix("http://"), !line.hasPrefix("https://"), !line.hasPrefix("/") else { return nil }

        // Strip leading markdown decoration and label prefixes.
        while let first = line.first, "#-*>•".contains(first) {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for prefix in labelPrefixes where line.lowercased().hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        line = line.replacingOccurrences(of: "**", with: "")
        line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        while let last = line.last, ".,:;".contains(last) {
            line.removeLast()
        }
        line = line.trimmingCharacters(in: .whitespaces)

        guard line.count >= 6, !noise.contains(line.lowercased()) else { return nil }

        if line.count > 90 {
            let head = line.prefix(90)
            let cut = head.lastIndex(of: " ") ?? head.endIndex
            line = String(head[..<cut]) + "…"
        }
        return line
    }

    /// Picks a representative subset of a session's user prompts: always the
    /// first (the session's intent) and the last, with the middle sampled
    /// evenly, so long sessions still yield a spread of what happened.
    static func sampled(_ texts: [String], limit: Int = 5) -> [String] {
        guard texts.count > limit, limit > 1 else { return texts }
        var indices: Set<Int> = [0, texts.count - 1]
        let middleSlots = limit - 2
        if middleSlots > 0 {
            for slot in 1...middleSlots {
                indices.insert(slot * (texts.count - 1) / (middleSlots + 1))
            }
        }
        return indices.sorted().map { texts[$0] }
    }
}

/// Groups per-file digests by project and folds each group into one
/// `WorkActivity` with feature-level detail.
enum ActivityBuilder {
    private static let maxFeatures = 8

    static func activities(from digests: [SessionDigest], source: WorkSource) -> [WorkActivity] {
        let live = digests.filter(\.hasActivity)
        let groups = Dictionary(grouping: live) { digest in
            digest.projectPath.map(normalizePath) ?? ""
        }

        return groups
            .map { path, sessions in activity(path: path, sessions: sessions, source: source) }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.summary < $1.summary
            }
    }

    private static func activity(path: String, sessions: [SessionDigest], source: WorkSource) -> WorkActivity {
        let ordered = sessions.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        let features = features(for: ordered)
        let projectPath = path.isEmpty ? nil : path
        let tokens = ordered.reduce(0) { $0 + $1.totalTokens }

        return WorkActivity(
            source: source,
            projectPath: projectPath,
            summary: summary(projectPath: projectPath, features: features, sessionCount: ordered.count),
            features: features,
            startedAt: ordered.compactMap(\.startedAt).min() ?? .distantPast,
            endedAt: ordered.compactMap(\.endedAt).max(),
            tokensUsed: tokens > 0 ? tokens : nil
        )
    }

    private static func features(for sessions: [SessionDigest]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for session in sessions {
            // The headline summary (Claude's ai-title, Codex's first
            // task_complete) leads, then the user's own words.
            var candidates: [String] = []
            if let headline = session.assistantSummaries.first {
                candidates.append(headline)
            }
            candidates += FeatureExtraction.sampled(session.userTexts)
            candidates += session.assistantSummaries.dropFirst()

            for raw in candidates {
                guard result.count < maxFeatures else { return result }
                guard let phrase = FeatureExtraction.phrase(from: raw),
                      seen.insert(phrase.lowercased()).inserted
                else { continue }
                result.append(phrase)
            }
        }
        return result
    }

    private static func summary(projectPath: String?, features: [String], sessionCount: Int) -> String {
        let projectName = projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        var summary: String
        switch (projectName, features.isEmpty) {
        case (let name?, false):
            summary = "\(name): \(features.prefix(3).joined(separator: ", "))"
        case (let name?, true):
            summary = "Worked in \(name)"
        case (nil, false):
            summary = features.prefix(3).joined(separator: ", ")
        case (nil, true):
            summary = "Coding session"
        }
        if sessionCount > 1 {
            summary += " · \(sessionCount) sessions"
        }
        if summary.count > 160 {
            summary = String(summary.prefix(159)) + "…"
        }
        return summary
    }

    private static func normalizePath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
