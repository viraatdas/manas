import XCTest
@testable import Manas

final class JudgeOutputParserTests: XCTestCase {
    private let todoID = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"

    func testParsesPlainJSON() throws {
        let json = JudgeFixtures.modelReplyJSON(
            verdicts: [(id: todoID, status: "done", evidence: "Merged in the 2:01 PM claude session")],
            discovered: [(title: "Debugged flaky CI", evidence: "The codex session touched CI configs", source: "codex")]
        )
        let output = try JudgeOutputParser.parse(json)
        XCTAssertEqual(output.verdicts.count, 1)
        XCTAssertEqual(output.verdicts[0].todoID, todoID)
        XCTAssertEqual(output.verdicts[0].status, .done)
        XCTAssertEqual(output.verdicts[0].evidence, "Merged in the 2:01 PM claude session")
        XCTAssertEqual(output.discovered.count, 1)
        XCTAssertEqual(output.discovered[0].title, "Debugged flaky CI")
        XCTAssertEqual(output.discovered[0].source, .codex)
    }

    func testParsesFencedJSON() throws {
        let json = """
        ```json
        {"verdicts": [{"todoID": "\(todoID)", "status": "in_progress", "evidence": "Work started"}], "discovered": []}
        ```
        """
        let output = try JudgeOutputParser.parse(json)
        XCTAssertEqual(output.verdicts[0].status, .inProgress)
    }

    func testParsesBareFence() throws {
        let json = """
        ```
        {"verdicts": [], "discovered": [{"title": "Wrote docs", "evidence": "The claude session edited README"}]}
        ```
        """
        let output = try JudgeOutputParser.parse(json)
        XCTAssertEqual(output.discovered[0].title, "Wrote docs")
    }

    func testParsesJSONWithSurroundingProse() throws {
        let text = """
        Here is my assessment of the day:
        {"verdicts": [{"todoID": "\(todoID)", "status": "not_started", "evidence": "No related work in any session"}], "discovered": []}
        Hope that helps! Let me know if you need anything {else}.
        """
        let output = try JudgeOutputParser.parse(text)
        XCTAssertEqual(output.verdicts[0].status, .notStarted)
    }

    func testParsesVerdictsKeyedByID() throws {
        let json = """
        {"verdicts": {"\(todoID)": {"status": "done", "evidence": "Shipped"}}, "discovered": []}
        """
        let output = try JudgeOutputParser.parse(json)
        XCTAssertEqual(output.verdicts.count, 1)
        XCTAssertEqual(output.verdicts[0].todoID, todoID)
        XCTAssertEqual(output.verdicts[0].status, .done)
    }

    func testAlternateTodoIDKeys() throws {
        let json = """
        {"verdicts": [
            {"todo_id": "\(todoID)", "status": "done", "evidence": "A"},
            {"id": "\(todoID)", "status": "unknown", "evidence": "B"}
        ], "discovered": []}
        """
        let output = try JudgeOutputParser.parse(json)
        XCTAssertEqual(output.verdicts.map(\.todoID), [todoID, todoID])
    }

    func testStatusLeniency() {
        XCTAssertEqual(Verdict.Status(lenient: "done"), .done)
        XCTAssertEqual(Verdict.Status(lenient: "DONE"), .done)
        XCTAssertEqual(Verdict.Status(lenient: "completed"), .done)
        XCTAssertEqual(Verdict.Status(lenient: "in_progress"), .inProgress)
        XCTAssertEqual(Verdict.Status(lenient: "In Progress"), .inProgress)
        XCTAssertEqual(Verdict.Status(lenient: "inProgress"), .inProgress)
        XCTAssertEqual(Verdict.Status(lenient: "not_started"), .notStarted)
        XCTAssertEqual(Verdict.Status(lenient: "not-started"), .notStarted)
        XCTAssertEqual(Verdict.Status(lenient: "unknown"), .unknown)
        XCTAssertEqual(Verdict.Status(lenient: "banana"), .unknown)
        XCTAssertEqual(Verdict.Status(lenient: nil), .unknown)
    }

    func testMissingEvidenceDefaultsToEmpty() throws {
        let json = #"{"verdicts": [{"todoID": "ABC", "status": "done"}], "discovered": []}"#
        let output = try JudgeOutputParser.parse(json)
        XCTAssertEqual(output.verdicts[0].evidence, "")
    }

    func testDiscoverySourceDefaultsToClaude() throws {
        let json = #"{"verdicts": [], "discovered": [{"title": "Planned the offsite", "evidence": "Granola-ish"}]}"#
        let output = try JudgeOutputParser.parse(json)
        XCTAssertEqual(output.discovered[0].source, .claude)
    }

    func testInvalidDiscoverySourceDefaultsToClaude() throws {
        let json = #"{"verdicts": [], "discovered": [{"title": "X", "evidence": "Y", "source": "carrier-pigeon"}]}"#
        let output = try JudgeOutputParser.parse(json)
        XCTAssertEqual(output.discovered[0].source, .claude)
    }

    func testDiscoveryWithoutTitleDropped() throws {
        let json = #"{"verdicts": [], "discovered": [{"evidence": "orphan evidence"}]}"#
        let output = try JudgeOutputParser.parse(json)
        XCTAssertTrue(output.discovered.isEmpty)
    }

    func testJSONWithNeitherKeyThrows() {
        XCTAssertThrowsError(try JudgeOutputParser.parse(#"{"hello": 1}"#)) { error in
            guard case JudgeError.malformedModelOutput = error else {
                return XCTFail("Expected malformedModelOutput, got \(error)")
            }
        }
    }

    func testProseOnlyThrows() {
        XCTAssertThrowsError(try JudgeOutputParser.parse("Sorry, I could not judge the todos today.")) { error in
            guard case JudgeError.malformedModelOutput = error else {
                return XCTFail("Expected malformedModelOutput, got \(error)")
            }
        }
    }

    func testEmptyTextThrows() {
        XCTAssertThrowsError(try JudgeOutputParser.parse(""))
    }
}
