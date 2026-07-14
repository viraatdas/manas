import Foundation
import XCTest
@testable import Manas

/// Shared scaffolding for fixture-based ingestion tests: a fixed UTC calendar
/// so results don't depend on the machine's timezone, a fixed fixture day,
/// and helpers to write .jsonl files with controlled on-disk dates.
enum IngestionFixtures {
    /// All fixtures live on 2026-07-10 (UTC).
    static let day = date("2026-07-10T12:00:00Z")

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ iso: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(iso)
    }

    static func makeTempDirectory(function: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasIngestionTests-\(function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes JSONL lines and stamps the file's creation/modification dates so
    /// the sources' modified-on-the-day file filter sees the intended day.
    static func writeJSONL(
        lines: [String],
        to file: URL,
        created: Date = day,
        modified: Date = day
    ) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.creationDate: created, .modificationDate: modified],
            ofItemAtPath: file.path
        )
    }
}
