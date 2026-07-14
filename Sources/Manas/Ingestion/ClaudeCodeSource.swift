import Foundation

/// Reads Claude Code transcripts from `~/.claude/projects/<encoded-path>/*.jsonl`.
///
/// Each project directory holds one JSONL file per session. Lines are typed
/// (`user`, `assistant`, `ai-title`, `summary`, plus bookkeeping types we
/// ignore) and the schema varies across CLI versions, so every line is parsed
/// defensively and unparseable ones are skipped. Subagent transcripts live in
/// a `subagents/` subdirectory and are excluded by only listing direct
/// children; sidechain entries inside a session file are skipped via their
/// `isSidechain` flag.
struct ClaudeCodeSource: ActivitySource {
    var name: String { "Claude Code" }

    let projectsDirectory: URL
    let calendar: Calendar

    /// Total session files read per fetch, across all projects. The per-day
    /// modification-date filter does the real work; this is a backstop.
    private static let maxFilesPerFetch = 400

    init(projectsDirectory: URL? = nil, calendar: Calendar = .current) {
        self.projectsDirectory = projectsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
        self.calendar = calendar
    }

    /// Runs off the main thread (nonisolated async); returns [] when the
    /// projects directory doesn't exist.
    func fetchActivities(for date: Date) async throws -> [WorkActivity] {
        let window = DayWindow(containing: date, calendar: calendar)
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var digests: [SessionDigest] = []
        var filesRead = 0
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            for file in TranscriptFiles.jsonlFiles(in: dir, overlapping: window) {
                guard filesRead < Self.maxFilesPerFetch else { break }
                filesRead += 1
                let digest = await Self.digest(of: file, window: window)
                if digest.hasActivity {
                    digests.append(digest)
                }
            }
        }
        return ActivityBuilder.activities(from: digests, source: .claude)
    }

    /// Streams one session file line by line and folds it into a digest.
    /// A read error partway through keeps whatever was already collected.
    static func digest(of file: URL, window: DayWindow) async -> SessionDigest {
        var digest = SessionDigest()
        var aiTitle: String?

        do {
            for try await line in file.lines {
                guard let entry = TranscriptJSON.object(fromLine: line) else { continue }
                switch entry["type"] as? String {
                case "user":
                    ingestUser(entry, into: &digest, window: window)
                case "assistant":
                    ingestAssistant(entry, into: &digest, window: window)
                case "ai-title":
                    // Session-level generated title — the best single feature
                    // phrase available. Later entries overwrite earlier ones.
                    aiTitle = entry["aiTitle"] as? String
                case "summary":
                    // Older CLI versions wrote {"type":"summary","summary":…}.
                    if let text = entry["summary"] as? String {
                        digest.addSummary(text)
                    }
                default:
                    break
                }
            }
        } catch {
            // Unreadable or truncated file: keep what we have.
        }

        if let aiTitle {
            digest.assistantSummaries.insert(aiTitle, at: 0)
        }
        return digest
    }

    private static func ingestUser(_ entry: [String: Any], into digest: inout SessionDigest, window: DayWindow) {
        guard entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true else { return }
        guard let timestamp = TranscriptJSON.date(entry["timestamp"]), window.contains(timestamp) else { return }

        if digest.projectPath == nil {
            digest.projectPath = entry["cwd"] as? String
        }
        digest.observe(timestamp)

        guard let message = entry["message"] as? [String: Any],
              let text = userText(from: message["content"])
        else { return }
        digest.addUserText(text)
    }

    private static func ingestAssistant(_ entry: [String: Any], into digest: inout SessionDigest, window: DayWindow) {
        guard entry["isSidechain"] as? Bool != true else { return }
        guard let timestamp = TranscriptJSON.date(entry["timestamp"]), window.contains(timestamp) else { return }

        if digest.projectPath == nil {
            digest.projectPath = entry["cwd"] as? String
        }
        digest.observe(timestamp)

        guard let message = entry["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }
        // Total processed tokens, cache included — matches how usage
        // dashboards report Claude Code consumption.
        digest.totalTokens += (TranscriptJSON.int(usage["input_tokens"]) ?? 0)
            + (TranscriptJSON.int(usage["output_tokens"]) ?? 0)
            + (TranscriptJSON.int(usage["cache_creation_input_tokens"]) ?? 0)
            + (TranscriptJSON.int(usage["cache_read_input_tokens"]) ?? 0)
    }

    /// A user entry's content is either a plain prompt string or an array of
    /// blocks (tool results, pasted text). Only human-authored text survives.
    private static func userText(from content: Any?) -> String? {
        if let text = content as? String {
            return text
        }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
}
