import Foundation

/// Reads CoreDuet's local `/app/usage` intervals for the requested day. This
/// is a private, schema-gated macOS store; failure stays isolated and appears
/// as source health instead of blocking the rest of the check-in.
struct ScreenTimeSource: ActivitySource {
    var source: WorkSource { .screenTime }
    var name: String { source.displayName }

    let databaseURL: URL
    let calendar: Calendar

    init(databaseURL: URL? = nil, calendar: Calendar = .current) {
        self.databaseURL = databaseURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db")
        self.calendar = calendar
    }

    func fetchActivities(for date: Date) async throws -> [WorkActivity] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ActivitySourceFailure.unavailable("Screen Time has no local activity database yet.")
        }
        let window = DayWindow(containing: date, calendar: calendar)
        let start = window.start.timeIntervalSinceReferenceDate
        let end = window.end.timeIntervalSinceReferenceDate
        let rows: [SQLiteRow]
        do {
            rows = try ReadOnlySQLiteDatabase.query(
                databaseURL,
                sql: """
                SELECT ZUUID AS uuid, ZVALUESTRING AS bundle_id,
                       ZSTARTDATE AS started_at, ZENDDATE AS ended_at
                FROM ZOBJECT
                WHERE ZSTREAMNAME = '/app/usage'
                  AND ZSTARTDATE < ?2 AND ZENDDATE > ?1
                  AND ZENDDATE > ZSTARTDATE
                ORDER BY ZSTARTDATE ASC, Z_PK ASC
                LIMIT 3000
                """,
                bindings: [.double(start), .double(end)]
            )
        } catch {
            throw map(error)
        }

        var seen: Set<String> = []
        var byBundle: [String: [Interval]] = [:]
        for row in rows {
            guard let bundleID = row["bundle_id"].string, !bundleID.isEmpty,
                  let rawStart = row["started_at"].double,
                  let rawEnd = row["ended_at"].double
            else { continue }
            let key = row["uuid"].string ?? "\(bundleID)-\(rawStart)-\(rawEnd)"
            guard seen.insert(key).inserted else { continue }
            let clippedStart = max(rawStart, start)
            let clippedEnd = min(rawEnd, end)
            guard clippedEnd > clippedStart else { continue }
            byBundle[bundleID, default: []].append(Interval(start: clippedStart, end: clippedEnd))
        }

        return byBundle.compactMap { bundleID, intervals -> WorkActivity? in
            let merged = Self.merge(intervals)
            let seconds = merged.reduce(0) { $0 + ($1.end - $1.start) }
            guard seconds >= 30, let first = merged.first, let last = merged.last else { return nil }
            let appName = Self.appName(for: bundleID)
            return WorkActivity(
                source: .screenTime,
                summary: "Used \(appName) for \(Self.duration(seconds))",
                features: [appName, Self.duration(seconds)],
                startedAt: Date(timeIntervalSinceReferenceDate: first.start),
                endedAt: Date(timeIntervalSinceReferenceDate: last.end)
            )
        }
        .sorted { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
        .suffix(20)
    }

    static func merge(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var result: [Interval] = []
        for interval in sorted {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1].end = max(last.end, interval.end)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    static func appName(for bundleID: String) -> String {
        let known: [String: String] = [
            "company.thebrowser.Browser": "Arc",
            "com.apple.dt.Xcode": "Xcode",
            "com.apple.MobileSMS": "Messages",
            "com.apple.Safari": "Safari",
            "com.apple.Terminal": "Terminal",
            "com.microsoft.VSCode": "Visual Studio Code",
            "com.tinyspeck.slackmacgap": "Slack",
            "notion.id": "Notion",
        ]
        if let known = known[bundleID] { return known }
        let raw = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return raw
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private func map(_ error: Error) -> ActivitySourceFailure {
        if let sqlite = error as? SQLiteReadError, sqlite.isAccessFailure {
            return .permissionRequired("Allow Manas in Full Disk Access to read Screen Time.")
        }
        return .readFailed("Screen Time could not be read on this version of macOS.")
    }

    struct Interval: Hashable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
    }
}
