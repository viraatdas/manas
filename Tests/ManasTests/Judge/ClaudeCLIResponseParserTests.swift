import XCTest
@testable import Manas

final class ClaudeCLIResponseParserTests: XCTestCase {
    func testParsesSingleResultObject() throws {
        let data = JudgeFixtures.cliEnvelopeJSON(
            result: "hello",
            inputTokens: 10,
            outputTokens: 53,
            cacheCreation: 8084,
            cacheRead: 17258,
            cost: 0.0181688
        )
        let reply = try ClaudeCLIResponseParser.parse(data)
        XCTAssertEqual(reply.text, "hello")
        XCTAssertEqual(reply.tokensIn, 10 + 8084 + 17258, "Cache tokens count toward tokensIn")
        XCTAssertEqual(reply.tokensOut, 53)
        XCTAssertEqual(reply.costUSD, 0.0181688, accuracy: 0.000_000_1)
        XCTAssertFalse(reply.isError)
    }

    /// Some CLI versions/settings print an array of events (system init,
    /// assistant messages, rate-limit notices) ending in a result event —
    /// mirrors real `claude -p 'say hi' --output-format json` output.
    func testParsesEventArray() throws {
        let json = #"""
        [
          {"type":"system","subtype":"init","cwd":"/tmp","session_id":"abc","model":"claude-haiku-4-5"},
          {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"output_tokens":3}},"session_id":"abc"},
          {"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}},
          {"type":"result","subtype":"success","is_error":false,"duration_ms":2088,"result":"hi there","total_cost_usd":0.018,"usage":{"input_tokens":10,"cache_creation_input_tokens":8084,"cache_read_input_tokens":17258,"output_tokens":53}}
        ]
        """#
        let reply = try ClaudeCLIResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(reply.text, "hi there")
        XCTAssertEqual(reply.tokensIn, 25352)
        XCTAssertEqual(reply.tokensOut, 53)
        XCTAssertEqual(reply.costUSD, 0.018, accuracy: 0.000_001)
        XCTAssertFalse(reply.isError)
    }

    func testParsesNewlineDelimitedEvents() throws {
        let json = """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"result","subtype":"success","is_error":false,"result":"streamed","usage":{"input_tokens":5,"output_tokens":7}}
        """
        let reply = try ClaudeCLIResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(reply.text, "streamed")
        XCTAssertEqual(reply.tokensIn, 5)
        XCTAssertEqual(reply.tokensOut, 7)
    }

    func testMissingUsageAndCostDefaultToZero() throws {
        let json = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#
        let reply = try ClaudeCLIResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(reply.tokensIn, 0)
        XCTAssertEqual(reply.tokensOut, 0)
        XCTAssertEqual(reply.costUSD, 0, "Cost is 0 when total_cost_usd is absent (subscription auth)")
        XCTAssertNil(reply.modelID, "No modelUsage in the envelope means no reported model")
    }

    func testParsesReportedModelFromModelUsage() throws {
        let json = #"{"type":"result","subtype":"success","is_error":false,"result":"ok","modelUsage":{"claude-sonnet-5":{"inputTokens":10,"outputTokens":3,"costUSD":0.01}}}"#
        let reply = try ClaudeCLIResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(reply.modelID, "claude-sonnet-5")
    }

    func testErrorEnvelopeFlagged() throws {
        let data = JudgeFixtures.cliEnvelopeJSON(result: "boom", isError: true, subtype: "error_during_execution")
        let reply = try ClaudeCLIResponseParser.parse(data)
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.subtype, "error_during_execution")
    }

    func testNonSuccessSubtypeWithoutIsErrorFlagged() throws {
        let json = #"{"type":"result","subtype":"error_max_turns","result":""}"#
        let reply = try ClaudeCLIResponseParser.parse(Data(json.utf8))
        XCTAssertTrue(reply.isError)
    }

    func testGarbageThrowsMalformedCLIOutput() {
        XCTAssertThrowsError(try ClaudeCLIResponseParser.parse(Data("not json at all".utf8))) { error in
            guard case JudgeError.malformedCLIOutput = error else {
                return XCTFail("Expected malformedCLIOutput, got \(error)")
            }
        }
    }

    func testEmptyOutputThrowsMalformedCLIOutput() {
        XCTAssertThrowsError(try ClaudeCLIResponseParser.parse(Data())) { error in
            guard case JudgeError.malformedCLIOutput = error else {
                return XCTFail("Expected malformedCLIOutput, got \(error)")
            }
        }
    }
}
