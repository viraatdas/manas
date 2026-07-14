import Foundation
import XCTest
@testable import Manas

/// Fixtures are modeled on the real ~/.claude/projects transcript schema
/// (CLI 2.1.x): typed JSONL lines with user/assistant messages carrying
/// timestamps, cwd, sidechain/meta flags, and per-message usage.
final class ClaudeCodeSourceTests: XCTestCase {
    private let day = IngestionFixtures.day
    private let calendar = IngestionFixtures.utcCalendar

    private func makeSource(projectsDirectory: URL) -> ClaudeCodeSource {
        ClaudeCodeSource(projectsDirectory: projectsDirectory, calendar: calendar)
    }

    // MARK: - Fixture lines

    private func userLine(text: String, at iso: String, cwd: String, sidechain: Bool = false, meta: Bool = false) -> String {
        let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
        return """
        {"parentUuid":null,"isSidechain":\(sidechain),"isMeta":\(meta),"type":"user","message":{"role":"user","content":"\(escaped)"},"uuid":"\(UUID().uuidString)","timestamp":"\(iso)","cwd":"\(cwd)","sessionId":"S1","version":"2.1.209","gitBranch":"HEAD"}
        """
    }

    private func toolResultLine(at iso: String, cwd: String) -> String {
        """
        {"type":"user","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"File created successfully"}]},"uuid":"\(UUID().uuidString)","timestamp":"\(iso)","cwd":"\(cwd)","sessionId":"S1"}
        """
    }

    private func assistantLine(at iso: String, cwd: String, input: Int, output: Int, cacheCreate: Int = 0, cacheRead: Int = 0) -> String {
        """
        {"parentUuid":"p","isSidechain":false,"type":"assistant","message":{"model":"claude-haiku-4-5","id":"msg_1","role":"assistant","content":[{"type":"text","text":"Working on it."}],"stop_reason":"tool_use","usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreate),"cache_read_input_tokens":\(cacheRead),"output_tokens":\(output),"service_tier":"standard"}},"uuid":"\(UUID().uuidString)","timestamp":"\(iso)","cwd":"\(cwd)","sessionId":"S1","version":"2.1.209"}
        """
    }

    // MARK: - Tests

    func testMissingDirectoryReturnsEmpty() async throws {
        let source = makeSource(projectsDirectory: URL(fileURLWithPath: "/nonexistent/manas-tests/\(UUID())"))
        let activities = try await source.fetchActivities(for: day)
        XCTAssertEqual(activities, [])
    }

    func testParsesSessionIntoFeatureLevelActivity() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/dev/code/manas"
        let lines = [
            #"{"type":"mode","mode":"normal","sessionId":"S1"}"#,
            #"{"type":"file-history-snapshot","messageId":"m1","snapshot":{"trackedFileBackups":{}},"isSnapshotUpdate":false}"#,
            userLine(text: "Objective: Implement usage sparkline in Manas\nDone when: swift test passes", at: "2026-07-10T17:00:00.000Z", cwd: cwd),
            assistantLine(at: "2026-07-10T17:01:00.000Z", cwd: cwd, input: 12, output: 88, cacheCreate: 100, cacheRead: 200),
            toolResultLine(at: "2026-07-10T17:02:00.000Z", cwd: cwd),
            userLine(text: "<local-command-stdout>ran /compact</local-command-stdout>", at: "2026-07-10T17:02:30.000Z", cwd: cwd, meta: true),
            userLine(text: "Explore the repo structure thoroughly", at: "2026-07-10T17:03:00.000Z", cwd: cwd, sidechain: true),
            userLine(text: "also add a 7-day sparkline to the usage panel", at: "2026-07-10T17:04:00.000Z", cwd: cwd),
            "this line is not valid json {{{",
            assistantLine(at: "2026-07-10T17:05:00.000Z", cwd: cwd, input: 5, output: 50),
            #"{"type":"last-prompt","lastPrompt":"also add a 7-day sparkline…","leafUuid":"x","sessionId":"S1"}"#,
            #"{"type":"ai-title","aiTitle":"Add usage sparkline and panel","sessionId":"S1"}"#,
        ]
        try IngestionFixtures.writeJSONL(
            lines: lines,
            to: root.appendingPathComponent("-Users-dev-code-manas/session-1.jsonl")
        )

        let activities = try await makeSource(projectsDirectory: root).fetchActivities(for: day)

        XCTAssertEqual(activities.count, 1)
        let activity = try XCTUnwrap(activities.first)
        XCTAssertEqual(activity.source, .claude)
        XCTAssertEqual(activity.projectPath, cwd)
        XCTAssertEqual(activity.startedAt, IngestionFixtures.date("2026-07-10T17:00:00Z"))
        XCTAssertEqual(activity.endedAt, IngestionFixtures.date("2026-07-10T17:05:00Z"))
        XCTAssertEqual(activity.tokensUsed, 12 + 88 + 100 + 200 + 5 + 50)

        // Feature-level detail: the generated session title leads, and the
        // user's own prompts are represented with label prefixes stripped.
        XCTAssertEqual(activity.features.first, "Add usage sparkline and panel")
        XCTAssertTrue(activity.features.contains("Implement usage sparkline in Manas"))
        XCTAssertTrue(activity.features.contains("also add a 7-day sparkline to the usage panel"))
        // Sidechain, meta, and command-wrapper texts never become features.
        XCTAssertFalse(activity.features.contains { $0.contains("Explore the repo") })
        XCTAssertFalse(activity.features.contains { $0.contains("local-command-stdout") })
        XCTAssertTrue(activity.summary.contains("manas"))
    }

    func testMergesSessionsOfSameProjectAndSplitsDistinctProjects() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manasCwd = "/Users/dev/code/manas"
        let otherCwd = "/Users/dev/code/other"

        try IngestionFixtures.writeJSONL(
            lines: [
                userLine(text: "build the settings screen", at: "2026-07-10T09:00:00.000Z", cwd: manasCwd),
                assistantLine(at: "2026-07-10T09:05:00.000Z", cwd: manasCwd, input: 10, output: 20),
            ],
            to: root.appendingPathComponent("-Users-dev-code-manas/session-a.jsonl")
        )
        try IngestionFixtures.writeJSONL(
            lines: [
                userLine(text: "wire the aggregator into the store", at: "2026-07-10T15:00:00.000Z", cwd: manasCwd),
                assistantLine(at: "2026-07-10T15:30:00.000Z", cwd: manasCwd, input: 30, output: 40),
            ],
            to: root.appendingPathComponent("-Users-dev-code-manas/session-b.jsonl")
        )
        try IngestionFixtures.writeJSONL(
            lines: [
                userLine(text: "fix the flaky deploy script", at: "2026-07-10T11:00:00.000Z", cwd: otherCwd),
            ],
            to: root.appendingPathComponent("-Users-dev-code-other/session-c.jsonl")
        )

        let activities = try await makeSource(projectsDirectory: root).fetchActivities(for: day)

        XCTAssertEqual(activities.count, 2)
        let manas = try XCTUnwrap(activities.first { $0.projectPath == manasCwd })
        XCTAssertEqual(manas.startedAt, IngestionFixtures.date("2026-07-10T09:00:00Z"))
        XCTAssertEqual(manas.endedAt, IngestionFixtures.date("2026-07-10T15:30:00Z"))
        XCTAssertEqual(manas.tokensUsed, 10 + 20 + 30 + 40)
        XCTAssertTrue(manas.features.contains("build the settings screen"))
        XCTAssertTrue(manas.features.contains("wire the aggregator into the store"))
        XCTAssertTrue(manas.summary.contains("2 sessions"))

        let other = try XCTUnwrap(activities.first { $0.projectPath == otherCwd })
        XCTAssertNil(other.tokensUsed)
        XCTAssertEqual(other.features, ["fix the flaky deploy script"])
    }

    func testSkipsFilesNotTouchedOnTargetDay() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Content would match the day, but the file was created and last
        // modified two days earlier — the file filter must skip it unopened.
        try IngestionFixtures.writeJSONL(
            lines: [userLine(text: "stale session work", at: "2026-07-10T10:00:00.000Z", cwd: "/Users/dev/code/manas")],
            to: root.appendingPathComponent("-Users-dev-code-manas/stale.jsonl"),
            created: IngestionFixtures.date("2026-07-08T10:00:00Z"),
            modified: IngestionFixtures.date("2026-07-08T11:00:00Z")
        )

        let activities = try await makeSource(projectsDirectory: root).fetchActivities(for: day)
        XCTAssertEqual(activities, [])
    }

    func testFiltersEntriesOutsideTargetDayWithinSpanningSession() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/dev/code/manas"
        try IngestionFixtures.writeJSONL(
            lines: [
                userLine(text: "yesterday's late-night refactor", at: "2026-07-09T23:50:00.000Z", cwd: cwd),
                userLine(text: "carry on into the morning", at: "2026-07-10T00:10:00.000Z", cwd: cwd),
                assistantLine(at: "2026-07-10T00:15:00.000Z", cwd: cwd, input: 7, output: 9),
            ],
            to: root.appendingPathComponent("-Users-dev-code-manas/spanning.jsonl")
        )

        let activities = try await makeSource(projectsDirectory: root).fetchActivities(for: day)

        XCTAssertEqual(activities.count, 1)
        let activity = try XCTUnwrap(activities.first)
        XCTAssertEqual(activity.startedAt, IngestionFixtures.date("2026-07-10T00:10:00Z"))
        XCTAssertFalse(activity.features.contains { $0.contains("yesterday") })
    }

    func testSessionWithEntriesOnlyOnOtherDaysProducesNothing() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // mtime passes the file filter, but every entry is from another day.
        try IngestionFixtures.writeJSONL(
            lines: [userLine(text: "different day entirely", at: "2026-07-09T10:00:00.000Z", cwd: "/Users/dev/code/manas")],
            to: root.appendingPathComponent("-Users-dev-code-manas/other-day.jsonl")
        )

        let activities = try await makeSource(projectsDirectory: root).fetchActivities(for: day)
        XCTAssertEqual(activities, [])
    }
}
