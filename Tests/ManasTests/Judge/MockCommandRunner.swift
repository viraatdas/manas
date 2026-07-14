import Foundation
@testable import Manas

/// Scripted CommandRunning: returns queued results in order and records every
/// invocation, so judge tests never touch a real binary.
final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Sendable {
        var executablePath: String
        var arguments: [String]
        var timeout: TimeInterval
    }

    private let lock = NSLock()
    private var queued: [Result<CommandOutput, Error>]
    private var recorded: [Call] = []

    init(results: [Result<CommandOutput, Error>] = []) {
        queued = results
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func enqueue(_ result: Result<CommandOutput, Error>) {
        lock.lock()
        defer { lock.unlock() }
        queued.append(result)
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let next = record(Call(executablePath: executablePath, arguments: arguments, timeout: timeout))
        guard let next else {
            throw CommandError.launchFailed("MockCommandRunner: no result queued for \(executablePath)")
        }
        return try next.get()
    }

    private func record(_ call: Call) -> Result<CommandOutput, Error>? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return queued.isEmpty ? nil : queued.removeFirst()
    }
}

/// Shared fixture builders for judge tests. JSON is assembled with
/// JSONSerialization so nested model replies are escaped correctly.
enum JudgeFixtures {
    static func cliEnvelopeJSON(
        result: String,
        inputTokens: Int = 1800,
        outputTokens: Int = 340,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        cost: Double? = 0.0123,
        isError: Bool = false,
        subtype: String = "success"
    ) -> Data {
        var envelope: [String: Any] = [
            "type": "result",
            "subtype": subtype,
            "is_error": isError,
            "result": result,
            "usage": [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "cache_creation_input_tokens": cacheCreation,
                "cache_read_input_tokens": cacheRead,
            ],
        ]
        if let cost {
            envelope["total_cost_usd"] = cost
        }
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    static func cliSuccess(
        result: String,
        inputTokens: Int = 1800,
        outputTokens: Int = 340,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        cost: Double? = 0.0123
    ) -> CommandOutput {
        CommandOutput(
            exitStatus: 0,
            stdout: cliEnvelopeJSON(
                result: result,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreation: cacheCreation,
                cacheRead: cacheRead,
                cost: cost
            )
        )
    }

    static func modelReplyJSON(
        verdicts: [(id: String, status: String, evidence: String)],
        discovered: [(title: String, evidence: String, source: String?)] = []
    ) -> String {
        let payload: [String: Any] = [
            "verdicts": verdicts.map { verdict -> [String: Any] in
                ["todoID": verdict.id, "status": verdict.status, "evidence": verdict.evidence]
            },
            "discovered": discovered.map { discovery -> [String: Any] in
                var item: [String: Any] = ["title": discovery.title, "evidence": discovery.evidence]
                if let source = discovery.source {
                    item["source"] = source
                }
                return item
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}
