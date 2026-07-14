import Foundation
import XCTest
@testable import Manas

final class FeatureExtractionTests: XCTestCase {
    func testStripsLabelPrefixAndKeepsFirstMeaningfulLine() {
        XCTAssertEqual(
            FeatureExtraction.phrase(from: "Objective: Implement usage sparkline in Manas\nDone when: tests pass"),
            "Implement usage sparkline in Manas"
        )
    }

    func testStripsMarkdownDecorationAndLinks() {
        XCTAssertEqual(
            FeatureExtraction.phrase(from: "## Replaced the viewer in [DeviceViewer.tsx](/x/y.tsx:1)."),
            "Replaced the viewer in DeviceViewer.tsx"
        )
    }

    func testRejectsMachineNoise() {
        XCTAssertNil(FeatureExtraction.phrase(from: "<command-name>/loop</command-name>"))
        XCTAssertNil(FeatureExtraction.phrase(from: "[Request interrupted by user]"))
        XCTAssertNil(FeatureExtraction.phrase(from: "ok"))
        XCTAssertNil(FeatureExtraction.phrase(from: "continue"))
        XCTAssertNil(FeatureExtraction.phrase(from: "   "))
        XCTAssertNil(FeatureExtraction.phrase(from: "y"))
        XCTAssertNil(FeatureExtraction.phrase(from: "https://example.slack.com/archives/C0B/p178"))
        XCTAssertNil(FeatureExtraction.phrase(from: "/compact"))
    }

    func testCapsLongPhrasesAtWordBoundary() {
        let long = "implement the expanded usage panel with a per-session table, sparkline chart, model picker, and a whole lot more detail than fits"
        let phrase = FeatureExtraction.phrase(from: long)
        let unwrapped = try! XCTUnwrap(phrase)
        XCTAssertLessThanOrEqual(unwrapped.count, 91)
        XCTAssertTrue(unwrapped.hasSuffix("…"))
        XCTAssertTrue(unwrapped.hasPrefix("implement the expanded usage panel"))
    }

    func testSamplingKeepsFirstAndLastOfLongSessions() {
        let texts = (0..<20).map { "prompt number \($0)" }
        let sampled = FeatureExtraction.sampled(texts, limit: 5)
        XCTAssertEqual(sampled.count, 5)
        XCTAssertEqual(sampled.first, "prompt number 0")
        XCTAssertEqual(sampled.last, "prompt number 19")
    }

    func testSamplingLeavesShortListsAlone() {
        let texts = ["one", "two", "three"]
        XCTAssertEqual(FeatureExtraction.sampled(texts, limit: 5), texts)
    }
}
