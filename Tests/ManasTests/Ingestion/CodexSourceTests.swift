import Foundation
import XCTest
@testable import Manas

/// Fixtures are modeled on the real ~/.codex/sessions rollout schema
/// (CLI 0.1xx): envelope lines {"timestamp","type","payload"} with
/// session_meta, event_msg (user_message / token_count / task_complete),
/// and response_item entries.
final class CodexSourceTests: XCTestCase {
    private let day = IngestionFixtures.day
    private let calendar = IngestionFixtures.utcCalendar

    private func makeSource(sessionsDirectory: URL) -> CodexSource {
        CodexSource(sessionsDirectory: sessionsDirectory, calendar: calendar)
    }

    // MARK: - Fixture lines

    private func sessionMetaLine(at iso: String, cwd: String) -> String {
        """
        {"timestamp":"\(iso)","type":"session_meta","payload":{"id":"019f0000-0000-7000-8000-000000000001","timestamp":"\(iso)","cwd":"\(cwd)","originator":"codex-tui","cli_version":"0.144.4","model_provider":"openai","base_instructions":{"text":"You are Codex…"}}}
        """
    }

    private func userMessageLine(text: String, at iso: String) -> String {
        """
        {"timestamp":"\(iso)","type":"event_msg","payload":{"type":"user_message","message":"\(text)","images":[],"local_images":[],"text_elements":[]}}
        """
    }

    private func responseItemUserLine(text: String, at iso: String) -> String {
        let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
        return """
        {"timestamp":"\(iso)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\(escaped)"}]}}
        """
    }

    private func tokenCountLine(total: Int, at iso: String) -> String {
        """
        {"timestamp":"\(iso)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(total - 500),"cached_input_tokens":100,"output_tokens":500,"reasoning_output_tokens":77,"total_tokens":\(total)},"last_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15},"model_context_window":258400},"rate_limits":{"limit_id":"codex"}}}
        """
    }

    private func taskCompleteLine(message: String, at iso: String) -> String {
        let escaped = message.replacingOccurrences(of: "\n", with: "\\n")
        return """
        {"timestamp":"\(iso)","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"\(escaped)","completed_at":1784057113}}
        """
    }

    // MARK: - Tests

    func testMissingDirectoryReturnsEmpty() async throws {
        let source = makeSource(sessionsDirectory: URL(fileURLWithPath: "/nonexistent/manas-tests/\(UUID())"))
        let activities = try await source.fetchActivities(for: day)
        XCTAssertEqual(activities, [])
    }

    func testParsesDatedRolloutIntoFeatureLevelActivity() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/dev/code/sf-electricity"
        let lines = [
            sessionMetaLine(at: "2026-07-10T17:10:00.000Z", cwd: cwd),
            #"{"timestamp":"2026-07-10T17:10:01.000Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/Users/dev/code/sf-electricity","approval_policy":"never"}}"#,
            // AGENTS.md boilerplate injected as a user-role response item must
            // not count as activity or leak into features.
            responseItemUserLine(text: "# AGENTS.md instructions for /Users/dev/code/sf-electricity\n<INSTRUCTIONS>skills…</INSTRUCTIONS>", at: "2026-07-10T17:10:02.000Z"),
            responseItemUserLine(text: "<environment_context>sandbox…</environment_context>", at: "2026-07-10T17:10:02.500Z"),
            userMessageLine(text: "rebuild the feeder viewer with hover labels", at: "2026-07-10T17:10:03.000Z"),
            // Newer CLIs duplicate the prompt as a response item — dedup keeps one.
            responseItemUserLine(text: "rebuild the feeder viewer with hover labels", at: "2026-07-10T17:10:03.100Z"),
            tokenCountLine(total: 19_515, at: "2026-07-10T17:20:00.000Z"),
            "garbage that is not json {{{",
            tokenCountLine(total: 25_000, at: "2026-07-10T17:25:00.000Z"),
            taskCompleteLine(message: "Replaced the viewer with the interactive feeder model in [DeviceViewer.tsx](/Users/dev/code/sf-electricity/DeviceViewer.tsx:1).\n\nVerified the build passes.", at: "2026-07-10T17:30:00.000Z"),
        ]
        try IngestionFixtures.writeJSONL(
            lines: lines,
            to: root.appendingPathComponent("2026/07/10/rollout-2026-07-10T17-10-00-abc.jsonl")
        )

        let activities = try await makeSource(sessionsDirectory: root).fetchActivities(for: day)

        XCTAssertEqual(activities.count, 1)
        let activity = try XCTUnwrap(activities.first)
        XCTAssertEqual(activity.source, .codex)
        XCTAssertEqual(activity.projectPath, cwd)
        XCTAssertEqual(activity.startedAt, IngestionFixtures.date("2026-07-10T17:10:03Z"))
        XCTAssertEqual(activity.endedAt, IngestionFixtures.date("2026-07-10T17:30:00Z"))
        // Cumulative totals: the latest snapshot, not a sum of snapshots.
        XCTAssertEqual(activity.tokensUsed, 25_000)

        // task_complete leads (markdown link stripped), then the user prompt —
        // present exactly once despite the duplicated entry.
        XCTAssertEqual(activity.features.first, "Replaced the viewer with the interactive feeder model in DeviceViewer.tsx")
        XCTAssertEqual(activity.features.filter { $0.contains("feeder viewer") && $0.contains("hover") }.count, 1)
        XCTAssertFalse(activity.features.contains { $0.contains("AGENTS.md") })
        XCTAssertTrue(activity.summary.contains("sf-electricity"))
    }

    func testTokenTotalsAccumulateAcrossContextCompaction() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Each compaction restarts the cumulative counter from the shrunken
        // context, so a long session's totals look like three ramps:
        // 19,515→25,000, reset, 8,000→12,000, reset, 5,000. The session
        // really used 25,000 + 12,000 + 5,000 tokens.
        let lines = [
            sessionMetaLine(at: "2026-07-10T09:00:00.000Z", cwd: "/Users/dev/code/marathon"),
            userMessageLine(text: "migrate the billing pipeline to the new schema", at: "2026-07-10T09:00:05.000Z"),
            tokenCountLine(total: 19_515, at: "2026-07-10T09:20:00.000Z"),
            tokenCountLine(total: 25_000, at: "2026-07-10T09:40:00.000Z"),
            #"{"timestamp":"2026-07-10T09:40:10.000Z","type":"compacted","payload":{"message":"Context was summarized to fit the window."}}"#,
            tokenCountLine(total: 8_000, at: "2026-07-10T10:00:00.000Z"),
            // A repeated identical snapshot is not a reset — no double count.
            tokenCountLine(total: 8_000, at: "2026-07-10T10:00:01.000Z"),
            tokenCountLine(total: 12_000, at: "2026-07-10T10:20:00.000Z"),
            #"{"timestamp":"2026-07-10T10:20:10.000Z","type":"compacted","payload":{"message":"Context was summarized to fit the window."}}"#,
            tokenCountLine(total: 5_000, at: "2026-07-10T10:30:00.000Z"),
        ]
        try IngestionFixtures.writeJSONL(
            lines: lines,
            to: root.appendingPathComponent("2026/07/10/rollout-2026-07-10T09-00-00-long.jsonl")
        )

        let activities = try await makeSource(sessionsDirectory: root).fetchActivities(for: day)

        let activity = try XCTUnwrap(activities.first)
        XCTAssertEqual(activity.tokensUsed, 42_000)
    }

    func testCumulativeTokenFoldingWithoutResetKeepsLatestTotal() {
        // Sanity check on the digest itself: monotonic totals (a session that
        // never compacted) fold to the final snapshot, not a sum of them.
        var digest = SessionDigest()
        for total in [1_000, 6_000, 6_000, 9_500] {
            digest.recordCumulativeTokens(total)
        }
        XCTAssertEqual(digest.totalTokens, 9_500)
    }

    func testParsesFlatLegacyLayout() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Older Codex versions wrote rollout files directly into sessions/
        // and carried user prompts only as response items.
        let lines = [
            sessionMetaLine(at: "2026-07-10T08:00:00.000Z", cwd: "/Users/dev/legacy-project"),
            responseItemUserLine(text: "add retry logic to the sync worker", at: "2026-07-10T08:00:05.000Z"),
            tokenCountLine(total: 4_200, at: "2026-07-10T08:15:00.000Z"),
        ]
        try IngestionFixtures.writeJSONL(
            lines: lines,
            to: root.appendingPathComponent("rollout-2026-07-10T08-00-00-legacy.jsonl")
        )

        let activities = try await makeSource(sessionsDirectory: root).fetchActivities(for: day)

        XCTAssertEqual(activities.count, 1)
        let activity = try XCTUnwrap(activities.first)
        XCTAssertEqual(activity.projectPath, "/Users/dev/legacy-project")
        XCTAssertEqual(activity.features, ["add retry logic to the sync worker"])
        XCTAssertEqual(activity.tokensUsed, 4_200)
    }

    func testPicksUpMidnightSpanningSessionFromPreviousDayDirectory() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Session started July 9 (lives in 09's directory) but ran past
        // midnight; the file's mtime is on the 10th so it must be read, and
        // only the 10th's entries counted.
        let lines = [
            sessionMetaLine(at: "2026-07-09T23:40:00.000Z", cwd: "/Users/dev/code/nightowl"),
            userMessageLine(text: "profile the startup path", at: "2026-07-09T23:45:00.000Z"),
            userMessageLine(text: "now fix the slow cold start", at: "2026-07-10T00:20:00.000Z"),
            tokenCountLine(total: 9_000, at: "2026-07-10T00:30:00.000Z"),
        ]
        try IngestionFixtures.writeJSONL(
            lines: lines,
            to: root.appendingPathComponent("2026/07/09/rollout-2026-07-09T23-40-00-night.jsonl"),
            created: IngestionFixtures.date("2026-07-09T23:40:00Z"),
            modified: IngestionFixtures.date("2026-07-10T00:30:00Z")
        )

        let activities = try await makeSource(sessionsDirectory: root).fetchActivities(for: day)

        XCTAssertEqual(activities.count, 1)
        let activity = try XCTUnwrap(activities.first)
        XCTAssertEqual(activity.startedAt, IngestionFixtures.date("2026-07-10T00:20:00Z"))
        XCTAssertEqual(activity.features, ["now fix the slow cold start"])
    }

    func testRolloutFromAnotherDayProducesNothing() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try IngestionFixtures.writeJSONL(
            lines: [
                sessionMetaLine(at: "2026-07-08T10:00:00.000Z", cwd: "/Users/dev/code/old"),
                userMessageLine(text: "old work from another day", at: "2026-07-08T10:01:00.000Z"),
            ],
            to: root.appendingPathComponent("2026/07/08/rollout-2026-07-08T10-00-00-old.jsonl"),
            created: IngestionFixtures.date("2026-07-08T10:00:00Z"),
            modified: IngestionFixtures.date("2026-07-08T10:30:00Z")
        )

        let activities = try await makeSource(sessionsDirectory: root).fetchActivities(for: day)
        XCTAssertEqual(activities, [])
    }
}
