import Foundation

/// What one claude CLI invocation came back with, before the model's own
/// JSON reply is interpreted.
struct ClaudeCLIReply: Hashable, Sendable {
    var text: String
    var tokensIn: Int
    var tokensOut: Int
    var costUSD: Double
    var isError: Bool
    var subtype: String?
}

/// Parses the claude CLI's `--output-format json` envelope. Depending on CLI
/// version and settings the output is a single result object, an array of
/// events ending in a result event, or newline-delimited events — all are
/// handled.
enum ClaudeCLIResponseParser {
    static func parse(_ data: Data) throws -> ClaudeCLIReply {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data), envelope.isResult {
            return reply(from: envelope)
        }
        if let events = try? decoder.decode([Envelope].self, from: data),
           let envelope = events.last(where: \.isResult) {
            return reply(from: envelope)
        }
        let text = String(decoding: data, as: UTF8.self)
        let lineEnvelopes = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Envelope.self, from: Data(line.utf8))
        }
        if let envelope = lineEnvelopes.last(where: \.isResult) {
            return reply(from: envelope)
        }
        throw JudgeError.malformedCLIOutput(String(text.prefix(300)))
    }

    private static func reply(from envelope: Envelope) -> ClaudeCLIReply {
        let usage = envelope.usage
        // Cache reads/writes are still tokens the model processed, so they
        // count toward tokensIn — the usage strip shows real consumption.
        let tokensIn = (usage?.inputTokens ?? 0)
            + (usage?.cacheCreationInputTokens ?? 0)
            + (usage?.cacheReadInputTokens ?? 0)
        let isError = (envelope.isError ?? false)
            || (envelope.subtype != nil && envelope.subtype != "success")
        return ClaudeCLIReply(
            text: envelope.result ?? "",
            tokensIn: tokensIn,
            tokensOut: usage?.outputTokens ?? 0,
            costUSD: envelope.totalCostUSD ?? 0,  // absent on subscription auth
            isError: isError,
            subtype: envelope.subtype
        )
    }

    /// Every field optional so non-result events in an event array (system
    /// init, assistant messages, rate-limit notices) decode too.
    private struct Envelope: Decodable {
        var type: String?
        var subtype: String?
        var isError: Bool?
        var result: String?
        var totalCostUSD: Double?
        var usage: Usage?

        var isResult: Bool { type == "result" || (type == nil && result != nil) }

        enum CodingKeys: String, CodingKey {
            case type, subtype, result, usage
            case isError = "is_error"
            case totalCostUSD = "total_cost_usd"
        }

        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }
}
