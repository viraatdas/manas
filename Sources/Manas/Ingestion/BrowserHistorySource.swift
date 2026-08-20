import Foundation

/// Reads same-day page visits from the browsers installed on this Mac. Full
/// URLs are reduced to host names and page titles before they leave this
/// source; credentials, query strings, fragments, and non-web schemes never
/// reach the judge.
///
/// Every installed browser is read, not just the default one. Asking the
/// system for the default browser and reading only that is tidier but wrong
/// in practice: people keep work in one browser and everything else in
/// another, and a day's real picture is the union of them. Reading them all
/// also means the answer does not silently change the day somebody switches
/// defaults. Visits are grouped by host at the end, so the same site open in
/// two browsers is one activity rather than two.
struct BrowserHistorySource: ActivitySource {
    var source: WorkSource { .browser }
    var name: String { source.displayName }

    /// Where one browser keeps its history. Chromium-family browsers keep a
    /// SQLite `History` file per profile directory under a user-data root;
    /// Safari keeps a single `History.db` with its own schema and epoch.
    struct Store: Sendable, Hashable {
        enum Flavor: Sendable, Hashable { case chromium, safari }
        var browser: String
        var flavor: Flavor
        var root: URL
    }

    let stores: [Store]
    let calendar: Calendar

    init(stores: [Store]? = nil, calendar: Calendar = .current) {
        self.stores = stores ?? Self.installedStores()
        self.calendar = calendar
    }

    /// The browsers that actually have a history store on this machine. The
    /// list is deliberately by path rather than by bundle id: a browser that
    /// has been installed and used leaves a profile directory whether or not
    /// it is running, registered, or the default.
    static func installedStores(home: URL? = nil) -> [Store] {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let candidates: [Store] = [
            Store(browser: "Arc", flavor: .chromium,
                  root: support.appendingPathComponent("Arc/User Data", isDirectory: true)),
            Store(browser: "Chrome", flavor: .chromium,
                  root: support.appendingPathComponent("Google/Chrome", isDirectory: true)),
            Store(browser: "Brave", flavor: .chromium,
                  root: support.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)),
            Store(browser: "Edge", flavor: .chromium,
                  root: support.appendingPathComponent("Microsoft Edge", isDirectory: true)),
            Store(browser: "Vivaldi", flavor: .chromium,
                  root: support.appendingPathComponent("Vivaldi", isDirectory: true)),
            Store(browser: "Dia", flavor: .chromium,
                  root: support.appendingPathComponent("Dia/User Data", isDirectory: true)),
            Store(browser: "Safari", flavor: .safari,
                  root: home.appendingPathComponent("Library/Safari", isDirectory: true)),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.root.path) }
    }

    func fetchActivities(for date: Date) async throws -> [WorkActivity] {
        let files = stores.flatMap(historyFiles(in:))
        guard !files.isEmpty else {
            throw ActivitySourceFailure.unavailable("No browser on this Mac has local history yet.")
        }

        let window = DayWindow(containing: date, calendar: calendar)
        var visits: [Visit] = []
        var lastError: Error?
        for file in files {
            do {
                visits += try readVisits(from: file, window: window)
            } catch {
                lastError = error
            }
        }
        // One unreadable profile among several is normal — a browser can be
        // mid-write, or a profile can be a leftover shell. Only a day that
        // produced nothing at all is worth failing on.
        if visits.isEmpty, let lastError {
            throw mappedFailure(lastError)
        }
        return buildActivities(from: visits)
    }

    /// Every history database belonging to one browser. Chromium splits by
    /// profile, so a person with a work and a personal profile has two.
    private func historyFiles(in store: Store) -> [HistoryFile] {
        let fileManager = FileManager.default
        switch store.flavor {
        case .safari:
            let database = store.root.appendingPathComponent("History.db")
            guard fileManager.fileExists(atPath: database.path) else { return [] }
            return [HistoryFile(url: database, flavor: .safari)]
        case .chromium:
            let profiles = (try? fileManager.contentsOfDirectory(
                at: store.root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return profiles
                .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
                .map { $0.appendingPathComponent("History") }
                .filter { fileManager.fileExists(atPath: $0.path) }
                .map { HistoryFile(url: $0, flavor: .chromium) }
        }
    }

    private func readVisits(from file: HistoryFile, window: DayWindow) throws -> [Visit] {
        let snapshot = try SQLiteSnapshot.make(of: file.url)
        defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }
        switch file.flavor {
        case .chromium: return try readChromiumVisits(snapshot.databaseURL, window: window)
        case .safari: return try readSafariVisits(snapshot.databaseURL, window: window)
        }
    }

    // Chromium counts microseconds from 1601-01-01; this is the gap to the
    // Unix epoch.
    private static let chromiumEpochOffsetMicroseconds = 11_644_473_600_000_000.0

    private func readChromiumVisits(_ database: URL, window: DayWindow) throws -> [Visit] {
        let offset = Self.chromiumEpochOffsetMicroseconds
        let start = window.start.timeIntervalSince1970 * 1_000_000 + offset
        let end = window.end.timeIntervalSince1970 * 1_000_000 + offset
        let rows = try ReadOnlySQLiteDatabase.query(
            database,
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
            guard let rawTime = row["visit_time"].double else { return nil }
            let duration = max(0, min(row["visit_duration"].double ?? 0, 3_600_000_000)) / 1_000_000
            return visit(
                url: row["url"].string,
                title: row["title"].string,
                timestamp: Date(timeIntervalSince1970: (rawTime - offset) / 1_000_000),
                duration: duration
            )
        }
    }

    /// Safari stores seconds from 2001-01-01 — the same reference date
    /// `Date` uses — and records no per-visit duration.
    private func readSafariVisits(_ database: URL, window: DayWindow) throws -> [Visit] {
        let rows = try ReadOnlySQLiteDatabase.query(
            database,
            sql: """
            SELECT i.url AS url, v.title AS title, v.visit_time AS visit_time
            FROM history_visits AS v
            JOIN history_items AS i ON i.id = v.history_item
            WHERE v.visit_time >= ?1 AND v.visit_time < ?2
            ORDER BY v.visit_time ASC, v.id ASC
            LIMIT 800
            """,
            bindings: [
                .double(window.start.timeIntervalSinceReferenceDate),
                .double(window.end.timeIntervalSinceReferenceDate),
            ]
        )
        return rows.compactMap { row in
            guard let rawTime = row["visit_time"].double else { return nil }
            return visit(
                url: row["url"].string,
                title: row["title"].string,
                timestamp: Date(timeIntervalSinceReferenceDate: rawTime),
                duration: 0
            )
        }
    }

    /// The one place a raw row becomes a visit, so both readers drop the same
    /// things: non-web schemes, hostless URLs, and untrimmed titles.
    private func visit(url: String?, title: String?, timestamp: Date, duration: TimeInterval) -> Visit? {
        guard let url,
              let components = URLComponents(string: url),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        return Visit(
            host: host,
            title: title.flatMap { ActivityPrivacySanitizer.text($0, limit: 120) },
            timestamp: timestamp,
            duration: duration
        )
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
                source: .browser,
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
            return .permissionRequired("Allow Manas to read browser history in Full Disk Access.")
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileReadNoSuchFileError].contains(cocoa.code) {
            return .permissionRequired("Allow Manas to read browser history in Full Disk Access.")
        }
        return .readFailed("Browser history could not be read right now.")
    }

    private struct HistoryFile: Sendable {
        var url: URL
        var flavor: Store.Flavor
    }

    private struct Visit: Sendable {
        var host: String
        var title: String?
        var timestamp: Date
        var duration: TimeInterval
    }
}
