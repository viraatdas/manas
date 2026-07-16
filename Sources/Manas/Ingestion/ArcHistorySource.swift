import Foundation

/// Reads same-day page visits from every Arc profile. Full URLs are reduced
/// to host names and page titles before they leave this source; credentials,
/// query strings, fragments, and non-web schemes never reach the judge.
struct ArcHistorySource: ActivitySource {
    var source: WorkSource { .arc }
    var name: String { source.displayName }

    let userDataDirectory: URL
    let calendar: Calendar

    init(userDataDirectory: URL? = nil, calendar: Calendar = .current) {
        self.userDataDirectory = userDataDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Arc/User Data", isDirectory: true)
        self.calendar = calendar
    }

    func fetchActivities(for date: Date) async throws -> [WorkActivity] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: userDataDirectory.path) else {
            throw ActivitySourceFailure.unavailable("Arc is not installed or has no local history yet.")
        }
        let profiles = (try? fileManager.contentsOfDirectory(
            at: userDataDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let historyFiles = profiles
            .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            .map { $0.appendingPathComponent("History") }
            .filter { fileManager.fileExists(atPath: $0.path) }

        guard !historyFiles.isEmpty else {
            throw ActivitySourceFailure.unavailable("Arc has no readable profile history yet.")
        }

        let window = DayWindow(containing: date, calendar: calendar)
        var visits: [Visit] = []
        var lastError: Error?
        for historyFile in historyFiles {
            do {
                visits += try readVisits(from: historyFile, window: window)
            } catch {
                lastError = error
            }
        }
        if visits.isEmpty, let lastError {
            throw mappedFailure(lastError)
        }
        return buildActivities(from: visits)
    }

    private func readVisits(from historyFile: URL, window: DayWindow) throws -> [Visit] {
        let snapshot = try SQLiteSnapshot.make(of: historyFile)
        defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }
        let chromiumOffsetMicroseconds = 11_644_473_600_000_000.0
        let start = window.start.timeIntervalSince1970 * 1_000_000 + chromiumOffsetMicroseconds
        let end = window.end.timeIntervalSince1970 * 1_000_000 + chromiumOffsetMicroseconds
        let rows = try ReadOnlySQLiteDatabase.query(
            snapshot.databaseURL,
            sql: """
            SELECT u.url AS url, u.title AS title,
                   v.visit_time AS visit_time, v.visit_duration AS visit_duration
            FROM visits AS v
            JOIN urls AS u ON u.id = v.url
            WHERE v.visit_time >= ?1 AND v.visit_time < ?2
              AND IFNULL(u.hidden, 0) = 0
            ORDER BY v.visit_time ASC, v.id ASC
            LIMIT 800
            """,
            bindings: [.double(start), .double(end)]
        )
        return rows.compactMap { row in
            guard let rawURL = row["url"].string,
                  let components = URLComponents(string: rawURL),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host?.lowercased(), !host.isEmpty,
                  let rawTime = row["visit_time"].double
            else { return nil }
            let timestamp = Date(timeIntervalSince1970: (rawTime - chromiumOffsetMicroseconds) / 1_000_000)
            let duration = max(0, min(row["visit_duration"].double ?? 0, 3_600_000_000)) / 1_000_000
            let title = row["title"].string.flatMap { ActivityPrivacySanitizer.text($0, limit: 120) }
            return Visit(host: host, title: title, timestamp: timestamp, duration: duration)
        }
    }

    private func buildActivities(from visits: [Visit]) -> [WorkActivity] {
        let grouped = Dictionary(grouping: visits, by: \.host)
        return grouped.compactMap { host, hostVisits -> WorkActivity? in
            guard let first = hostVisits.min(by: { $0.timestamp < $1.timestamp }),
                  let last = hostVisits.max(by: { $0.timestamp < $1.timestamp })
            else { return nil }
            var seenTitles: Set<String> = []
            let titles = hostVisits.compactMap(\.title).filter { seenTitles.insert($0.lowercased()).inserted }
            let summary = titles.first.map { "Browsed \(host): \($0)" } ?? "Browsed \(host)"
            let observedEnd = last.timestamp.addingTimeInterval(max(last.duration, 1))
            return WorkActivity(
                source: .arc,
                summary: summary,
                features: Array(titles.prefix(6)),
                startedAt: first.timestamp,
                endedAt: observedEnd
            )
        }
        .sorted { $0.startedAt < $1.startedAt }
        .suffix(20)
    }

    private func mappedFailure(_ error: Error) -> ActivitySourceFailure {
        if let sqlite = error as? SQLiteReadError, sqlite.isAccessFailure {
            return .permissionRequired("Allow Manas to read Arc history in Full Disk Access.")
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileReadNoSuchFileError].contains(cocoa.code) {
            return .permissionRequired("Allow Manas to read Arc history in Full Disk Access.")
        }
        return .readFailed("Arc history could not be read right now.")
    }

    private struct Visit: Sendable {
        var host: String
        var title: String?
        var timestamp: Date
        var duration: TimeInterval
    }
}
