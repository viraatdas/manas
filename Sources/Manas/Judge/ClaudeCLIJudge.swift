import Foundation

/// TodoJudge backed by the user's installed claude CLI (subscription auth —
/// no API key, no SDK). Shells out to
/// `claude -p <prompt> --output-format json --model <model>`, reads
/// usage/cost and the model that actually ran from the CLI's JSON envelope,
/// and parses the model's strict-JSON reply into verdicts and discoveries.
struct ClaudeCLIJudge: TodoJudge {
    var runner: any CommandRunning
    var locator: ClaudeCLILocator
    /// Seconds before a CLI call is killed.
    var timeout: TimeInterval
    var now: @Sendable () -> Date

    init(
        runner: any CommandRunning = ProcessCommandRunner(),
        locator: ClaudeCLILocator? = nil,
        timeout: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.locator = locator ?? ClaudeCLILocator(runner: runner)
        self.timeout = timeout
        self.now = now
    }

    func judge(todos: [Todo], activities: [WorkActivity], model: String) async throws -> JudgeResult {
        guard !todos.isEmpty || !activities.isEmpty else {
            let usage = UsageRecord(
                timestamp: now(), model: model,
                tokensIn: 0, tokensOut: 0, costUSD: 0,
                summary: "Nothing to judge"
            )
            return JudgeResult(usage: usage)
        }
        guard let cliPath = await locator.locate() else {
            throw JudgeError.cliNotFound
        }

        // Today's todos already carry the groups from earlier passes; feeding
        // those labels back keeps clusters stable across hourly re-checks.
        let existingGroups = Self.groupNames(in: todos)
        let basePrompt = JudgePromptBuilder.build(
            todos: todos, activities: activities, existingGroups: existingGroups
        )
        var tokensIn = 0
        var tokensOut = 0
        var costUSD = 0.0
        // The usage record logs the model the CLI reports having actually
        // run, falling back to the requested alias on older CLIs.
        var reportedModel = model
        var prompt = basePrompt
        var lastError: Error = JudgeError.malformedModelOutput("")

        // One honest attempt, then one retry with a return-only-JSON nudge.
        // Usage is accumulated across both calls so the record stays honest.
        for _ in 0..<2 {
            try Task.checkCancellation()
            let reply = try await invokeCLI(at: cliPath, prompt: prompt, model: model)
            tokensIn += reply.tokensIn
            tokensOut += reply.tokensOut
            costUSD += reply.costUSD
            reportedModel = reply.modelID ?? reportedModel
            do {
                let output = try JudgeOutputParser.parse(reply.text)
                return result(
                    from: output, todos: todos, model: reportedModel,
                    tokensIn: tokensIn, tokensOut: tokensOut, costUSD: costUSD
                )
            } catch {
                lastError = error
                prompt = basePrompt + JudgePromptBuilder.jsonOnlyNudge
            }
        }
        throw lastError
    }

    private func invokeCLI(at path: String, prompt: String, model: String) async throws -> ClaudeCLIReply {
        let output: CommandOutput
        do {
            output = try await runner.run(
                executablePath: path,
                arguments: ["-p", prompt, "--output-format", "json", "--model", model],
                timeout: timeout
            )
        } catch CommandError.timedOut {
            throw JudgeError.timedOut(seconds: timeout)
        } catch CommandError.launchFailed(let message) {
            throw JudgeError.launchFailed(message)
        }
        guard output.exitStatus == 0 else {
            let stderr = String(decoding: output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw JudgeError.nonZeroExit(code: output.exitStatus, stderr: String(stderr.prefix(500)))
        }
        let reply = try ClaudeCLIResponseParser.parse(output.stdout)
        if reply.isError {
            let message = reply.text.isEmpty ? (reply.subtype ?? "unknown error") : reply.text
            throw JudgeError.cliReportedError(String(message.prefix(500)))
        }
        return reply
    }

    private func result(
        from output: ModelJudgeOutput,
        todos: [Todo],
        model: String,
        tokensIn: Int,
        tokensOut: Int,
        costUSD: Double
    ) -> JudgeResult {
        let judgedAt = now()
        let todoIDs = Set(todos.map(\.id))
        var verdicts: [UUID: Verdict] = [:]
        var groups: [UUID: String] = [:]
        for item in output.verdicts {
            guard let id = UUID(uuidString: item.todoID), todoIDs.contains(id) else { continue }
            verdicts[id] = Verdict(status: item.status, evidence: item.evidence, judgedAt: judgedAt)
            if let group = TodoGroupName.normalized(item.group) {
                groups[id] = group
            }
        }
        let discovered = output.discovered.map { item in
            DiscoveredActivity(
                title: item.title, evidence: item.evidence,
                source: item.source, group: item.group
            )
        }
        let usage = UsageRecord(
            timestamp: judgedAt,
            model: model,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            costUSD: costUSD,
            summary: summaryLine(judged: verdicts.count, discovered: discovered.count)
        )
        return JudgeResult(verdicts: verdicts, groups: groups, discovered: discovered, usage: usage)
    }

    /// Distinct group labels already on the passed todos, first-appearance
    /// order, so the prompt can ask the model to reuse them.
    private static func groupNames(in todos: [Todo]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for todo in todos {
            guard let group = todo.group else { continue }
            if seen.insert(TodoGroupName.key(for: group)).inserted {
                labels.append(group)
            }
        }
        return labels
    }

    private func summaryLine(judged: Int, discovered: Int) -> String {
        "\(judged) \(judged == 1 ? "todo" : "todos") judged, \(discovered) discovered"
    }
}
