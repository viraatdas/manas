import Foundation

/// Reads Codex CLI rollout files from `~/.codex/sessions/YYYY/MM/DD/*.jsonl`
/// (and flat `~/.codex/sessions/*.jsonl` written by older versions).
///
/// Every line is an envelope `{"timestamp": ISO8601, "type": …, "payload": …}`.
/// The interesting entries: `session_meta`/`turn_context` carry the cwd,
/// `event_msg`+`user_message` carries user prompts, `event_msg`+`task_complete`
/// carries the agent's own summary of what it finished, and
/// `event_msg`+`token_count` carries cumulative session token totals, which
/// restart from the shrunken context after each compaction. Older
/// rollouts only have `response_item` user messages, which mix real prompts
/// with AGENTS.md/environment boilerplate that has to be filtered out.
struct CodexSource: ActivitySource {
    var source: WorkSource { .codex }
    var name: String { "Codex" }

    let sessionsDirectory: URL
    let calendar: Calendar

    private static let maxFilesPerFetch = 400

    init(sessionsDirectory: URL? = nil, calendar: Calendar = .current) {
        self.sessionsDirectory = sessionsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        self.calendar = calendar
    }

    /// Runs off the main thread (nonisolated async); returns [] when the
    /// sessions directory doesn't exist.
    func fetchActivities(for date: Date) async throws -> [WorkActivity] {
        let window = DayWindow(containing: date, calendar: calendar)

        var candidates: [URL] = []
        // The day's dated directory, plus the previous day's for sessions
        // that started before midnight and ran into the target day. The
        // mtime/creation overlap filter keeps the extra directory cheap.
        for dayStart in [window.start, calendar.date(byAdding: .day, value: -1, to: window.start)] {
            guard let dayStart, let dir = datedDirectory(for: dayStart) else { continue }
            candidates += TranscriptFiles.jsonlFiles(in: dir, overlapping: window)
        }
        // Legacy flat layout: rollout files directly in the sessions root.
        candidates += TranscriptFiles.jsonlFiles(in: sessionsDirectory, overlapping: window)

        var digests: [SessionDigest] = []
        for file in candidates.prefix(Self.maxFilesPerFetch) {
            let digest = await Self.digest(of: file, window: window)
            if digest.hasActivity {
                digests.append(digest)
            }
        }
        return ActivityBuilder.activities(from: digests, source: .codex)
    }

    /// Rollout files are placed in YYYY/MM/DD directories named for the
    /// session's *local* start date.
    private func datedDirectory(for dayStart: Date) -> URL? {
        let components = calendar.dateComponents([.year, .month, .day], from: dayStart)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        return sessionsDirectory
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
    }

    /// Streams one rollout file line by line and folds it into a digest.
    static func digest(of file: URL, window: DayWindow) async -> SessionDigest {
        var digest = SessionDigest()

        do {
            for try await line in file.lines {
                guard let envelope = TranscriptJSON.object(fromLine: line) else { continue }
                let payload = envelope["payload"] as? [String: Any]
                let timestamp = TranscriptJSON.date(envelope["timestamp"])

                switch envelope["type"] as? String {
                case "session_meta", "turn_context":
                    if digest.projectPath == nil {
                        digest.projectPath = payload?["cwd"] as? String
                    }
                case "event_msg":
                    guard let payload, let timestamp, window.contains(timestamp) else { continue }
                    ingestEvent(payload, at: timestamp, into: &digest)
                case "response_item":
                    guard let payload, let timestamp, window.contains(timestamp) else { continue }
                    ingestResponseItem(payload, at: timestamp, into: &digest)
                default:
                    break
                }
            }
        } catch {
            // Unreadable or truncated file: keep what we have.
        }
        return digest
    }

    private static func ingestEvent(_ payload: [String: Any], at timestamp: Date, into digest: inout SessionDigest) {
        switch payload["type"] as? String {
        case "user_message":
            digest.observe(timestamp)
            if let text = payload["message"] as? String {
                digest.addUserText(text)
            }
        case "task_complete":
            digest.observe(timestamp)
            // The agent's own recap of the finished task — the most
            // feature-dense line in the whole file.
            if let text = payload["last_agent_message"] as? String {
                digest.addSummary(text)
            }
        case "token_count":
            digest.observe(timestamp)
            // Totals are cumulative per session but restart after context
            // compaction; the digest banks each finished segment so
            // multi-compaction sessions count in full.
            if let info = payload["info"] as? [String: Any],
               let totals = info["total_token_usage"] as? [String: Any],
               let total = TranscriptJSON.int(totals["total_tokens"]) {
                digest.recordCumulativeTokens(total)
            }
        case "agent_message":
            digest.observe(timestamp)
        default:
            break
        }
    }

    /// Older rollouts carry user prompts only as response items; newer ones
    /// duplicate them there (the digest's text dedup drops the copy).
    private static func ingestResponseItem(_ payload: [String: Any], at timestamp: Date, into digest: inout SessionDigest) {
        guard payload["type"] as? String == "message",
              payload["role"] as? String == "user",
              let text = inputText(from: payload["content"]),
              isRealUserText(text)
        else { return }
        digest.observe(timestamp)
        digest.addUserText(text)
    }

    private static func inputText(from content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "input_text" else { return nil }
            return block["text"] as? String
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Filters the instruction boilerplate Codex injects as user-role
    /// messages: permissions/environment blocks and AGENTS.md contents.
    private static func isRealUserText(_ text: String) -> Bool {
        !(text.hasPrefix("<") || text.hasPrefix("# AGENTS.md") || text.hasPrefix("Caveat:"))
    }
}
