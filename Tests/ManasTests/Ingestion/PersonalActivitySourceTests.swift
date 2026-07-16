import Foundation
import SQLite3
import XCTest

@testable import Manas

final class PersonalActivitySourceTests: XCTestCase {
    func testArcReadsEveryProfileAndSanitizesURLs() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (offset, profile) in ["Default", "Profile 1"].enumerated() {
            let history = root.appendingPathComponent(profile).appendingPathComponent("History")
            try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
            try makeDatabase(history, sql: """
                CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, hidden INTEGER DEFAULT 0);
                CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, visit_duration INTEGER);
                INSERT INTO urls VALUES(1, 'https://user:secret@example.com/work?token=secret#private', 'Launch planning', 0);
                INSERT INTO visits VALUES(1, 1, \(chromiumTime(IngestionFixtures.date("2026-07-10T10:0\(offset):00Z"))), 120000000);
                """)
        }

        let activities = try await ArcHistorySource(
            userDataDirectory: root,
            calendar: IngestionFixtures.utcCalendar
        ).fetchActivities(for: IngestionFixtures.day)

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.source, .arc)
        XCTAssertTrue(activities.first?.summary.contains("example.com") == true)
        XCTAssertFalse(activities.first?.summary.contains("secret") == true)
        XCTAssertEqual(activities.first?.features, ["Launch planning"])
    }

    func testArcRejectsNonWebSchemes() async throws {
        let root = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("Default/History")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeDatabase(history, sql: """
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, hidden INTEGER DEFAULT 0);
            CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, visit_duration INTEGER);
            INSERT INTO urls VALUES(1, 'file:///private/secret', 'Secret file', 0);
            INSERT INTO visits VALUES(1, 1, \(chromiumTime(IngestionFixtures.date("2026-07-10T10:00:00Z"))), 0);
            """)

        let activities = try await ArcHistorySource(
            userDataDirectory: root,
            calendar: IngestionFixtures.utcCalendar
        ).fetchActivities(for: IngestionFixtures.day)

        XCTAssertEqual(activities, [])
    }

    func testScreenTimeMergesOverlappingIntervals() async throws {
        let directory = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("knowledgeC.db")
        let firstStart = IngestionFixtures.date("2026-07-10T09:00:00Z").timeIntervalSinceReferenceDate
        let firstEnd = IngestionFixtures.date("2026-07-10T09:30:00Z").timeIntervalSinceReferenceDate
        let secondStart = IngestionFixtures.date("2026-07-10T09:20:00Z").timeIntervalSinceReferenceDate
        let secondEnd = IngestionFixtures.date("2026-07-10T10:00:00Z").timeIntervalSinceReferenceDate
        try makeDatabase(database, sql: """
            CREATE TABLE ZOBJECT(Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZSTREAMNAME TEXT, ZVALUESTRING TEXT, ZSTARTDATE REAL, ZENDDATE REAL);
            INSERT INTO ZOBJECT VALUES(1, 'one', '/app/usage', 'com.apple.dt.Xcode', \(firstStart), \(firstEnd));
            INSERT INTO ZOBJECT VALUES(2, 'two', '/app/usage', 'com.apple.dt.Xcode', \(secondStart), \(secondEnd));
            """)

        let activities = try await ScreenTimeSource(
            databaseURL: database,
            calendar: IngestionFixtures.utcCalendar
        ).fetchActivities(for: IngestionFixtures.day)

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.summary, "Used Xcode for 1 hr")
        XCTAssertEqual(activities.first?.source, .screenTime)
    }

    func testMessagesReadsTextWithoutContactIdentifiers() async throws {
        let directory = try IngestionFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("chat.db")
        let messageDate = Int64(
            IngestionFixtures.date("2026-07-10T11:00:00Z").timeIntervalSinceReferenceDate * 1_000_000_000
        )
        try makeDatabase(database, sql: """
            CREATE TABLE message(
                ROWID INTEGER PRIMARY KEY, date INTEGER, is_from_me INTEGER, text TEXT,
                attributedBody BLOB, service TEXT, is_empty INTEGER, is_system_message INTEGER,
                item_type INTEGER, is_spam INTEGER, associated_message_type INTEGER
            );
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            INSERT INTO message VALUES(1, \(messageDate), 1, 'Finished the launch brief for person@example.com', NULL, 'iMessage', 0, 0, 0, 0, 0);
            INSERT INTO chat_message_join VALUES(42, 1);
            """)

        let activities = try await MessagesSource(
            databaseURL: database,
            calendar: IngestionFixtures.utcCalendar
        ).fetchActivities(for: IngestionFixtures.day)

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.source, .messages)
        XCTAssertTrue(activities.first?.features.first?.contains("[email]") == true)
        XCTAssertFalse(activities.first?.features.first?.contains("person@example.com") == true)
        XCTAssertFalse(activities.first?.summary.contains("42") == true)
    }

    func testAttributedBodyExtractorIsDefensive() {
        let body = Data([0, 1, 2]) + Data("NSString\0Finished the release notes".utf8) + Data([0xff, 0])
        XCTAssertEqual(MessagesSource.textFromAttributedBody(body), "Finished the release notes")
        XCTAssertNil(MessagesSource.textFromAttributedBody(Data([0, 1, 2, 3])))
    }

    func testSanitizerCapsAndRedactsSensitiveText() {
        let raw = "Email person@example.com or call +1 (415) 555-0123 about https://example.com?a=secret"
        let result = ActivityPrivacySanitizer.text(raw, limit: 200)
        XCTAssertEqual(result, "Email [email] or call [phone] about [link]")
    }

    private func chromiumTime(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000 + 11_644_473_600_000_000)
    }

    private func makeDatabase(_ url: URL, sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("Could not open fixture database") }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        let error = message.map { String(cString: $0) }
        sqlite3_free(message)
        XCTAssertEqual(result, SQLITE_OK, error ?? "SQLite fixture setup failed")
    }
}
