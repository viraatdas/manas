import Foundation

/// The model's parsed reply, before ids are matched back to real todos.
struct ModelJudgeOutput: Hashable, Sendable {
    struct VerdictItem: Hashable, Sendable {
        var todoID: String
        var status: Verdict.Status
        var evidence: String
        var group: String?
    }

    struct DiscoveryItem: Hashable, Sendable {
        var title: String
        var evidence: String
        var source: WorkSource
        var group: String?
    }

    var verdicts: [VerdictItem]
    var discovered: [DiscoveryItem]
}

/// Parses the strict-JSON reply we asked the model for, tolerating the ways
/// models bend "strict": code fences, prose before/after the JSON, verdicts
/// keyed by id instead of listed, alternate key spellings, loose status
/// strings.
enum JudgeOutputParser {
    static func parse(_ text: String) throws -> ModelJudgeOutput {
        let decoder = JSONDecoder()
        for candidate in jsonCandidates(in: text) {
            if let raw = try? decoder.decode(RawOutput.self, from: Data(candidate.utf8)) {
                return output(from: raw)
            }
        }
        throw JudgeError.malformedModelOutput(String(text.prefix(300)))
    }

    // MARK: - JSON extraction

    /// Substrings worth trying to decode, in order of likelihood.
    static func jsonCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            candidates.append(trimmed)
        }
        candidates.append(contentsOf: fencedBlocks(in: text))
        if let balanced = firstBalancedObject(in: text) {
            candidates.append(balanced)
        }
        return candidates
    }

    /// Contents of ``` fenced blocks, with any language tag dropped.
    private static func fencedBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        let parts = text.components(separatedBy: "```")
        var index = 1
        while index < parts.count {
            var block = parts[index]
            if let newline = block.firstIndex(of: "\n") {
                let firstLine = block[..<newline].trimmingCharacters(in: .whitespaces)
                if firstLine.isEmpty || firstLine.allSatisfy(\.isLetter) {
                    block = String(block[block.index(after: newline)...])
                }
            }
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(trimmed)
            }
            index += 2
        }
        return blocks
    }

    /// The first brace-balanced object in the text, so prose before or after
    /// the JSON doesn't break parsing. String-aware: braces inside JSON
    /// strings don't count.
    private static func firstBalancedObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Mapping

    private static func output(from raw: RawOutput) -> ModelJudgeOutput {
        let verdicts = raw.verdicts.compactMap { item -> ModelJudgeOutput.VerdictItem? in
            guard let todoID = item.todoID, !todoID.isEmpty else { return nil }
            return ModelJudgeOutput.VerdictItem(
                todoID: todoID,
                status: Verdict.Status(lenient: item.status),
                evidence: item.evidence ?? "",
                group: item.group
            )
        }
        let discovered = raw.discovered.compactMap { item -> ModelJudgeOutput.DiscoveryItem? in
            guard let title = item.title, !title.isEmpty else { return nil }
            return ModelJudgeOutput.DiscoveryItem(
                title: title,
                evidence: item.evidence ?? "",
                source: item.source.flatMap { WorkSource(rawValue: $0.lowercased()) } ?? .claude,
                group: item.group
            )
        }
        return ModelJudgeOutput(verdicts: verdicts, discovered: discovered)
    }

    // MARK: - Raw decodable shapes

    private struct RawOutput: Decodable {
        var verdicts: [RawVerdict]
        var discovered: [RawDiscovery]

        enum CodingKeys: String, CodingKey {
            case verdicts, discovered
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.verdicts) || container.contains(.discovered) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Neither verdicts nor discovered is present"
                ))
            }
            if let items = try? container.decode([RawVerdict].self, forKey: .verdicts) {
                verdicts = items
            } else if let keyed = try? container.decode([String: RawVerdict].self, forKey: .verdicts) {
                verdicts = keyed
                    .map { id, item in
                        var withID = item
                        withID.todoID = item.todoID ?? id
                        return withID
                    }
                    .sorted { ($0.todoID ?? "") < ($1.todoID ?? "") }
            } else {
                verdicts = []
            }
            discovered = (try? container.decode([RawDiscovery].self, forKey: .discovered)) ?? []
        }
    }

    private struct RawVerdict: Decodable {
        var todoID: String?
        var status: String?
        var evidence: String?
        var group: String?

        enum CodingKeys: String, CodingKey {
            case todoID
            case todo_id
            case todoId
            case id
            case status
            case evidence
            case group
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            todoID = container.lenientString(.todoID, .todo_id, .todoId, .id)
            status = container.lenientString(.status)
            evidence = container.lenientString(.evidence)
            group = container.lenientString(.group)
        }
    }

    private struct RawDiscovery: Decodable {
        var title: String?
        var evidence: String?
        var source: String?
        var group: String?
    }
}

private extension KeyedDecodingContainer {
    /// First present, non-nil string among `keys`; type mismatches read as nil.
    func lenientString(_ keys: Key...) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}

extension Verdict.Status {
    /// Maps loose model spellings ("in_progress", "In Progress", "DONE") onto
    /// the typed status; anything unrecognized is `.unknown`.
    init(lenient raw: String?) {
        let normalized = (raw ?? "").lowercased().filter(\.isLetter)
        switch normalized {
        case "done", "complete", "completed", "finished":
            self = .done
        case "inprogress", "started", "inflight":
            self = .inProgress
        case "notstarted", "unstarted":
            self = .notStarted
        default:
            self = .unknown
        }
    }
}
