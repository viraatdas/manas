import Foundation

/// Reads the day's messages — iMessage, SMS, and RCS alike — without joining
/// contact handles or chat names. Conversations are anonymous activity
/// clusters; only capped, redacted text snippets are passed to the judge and
/// raw rows are never persisted.
struct MessagesSource: ActivitySource {
    var source: WorkSource { .messages }
    var name: String { source.displayName }

    let databaseURL: URL
    let calendar: Calendar

    init(databaseURL: URL? = nil, calendar: Calendar = .current) {
        self.databaseURL = databaseURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Messages/chat.db")
        self.calendar = calendar
    }

    func fetchActivities(for date: Date) async throws -> [WorkActivity] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ActivitySourceFailure.unavailable("Messages has no local archive yet.")
        }
        let window = DayWindow(containing: date, calendar: calendar)
        let start = Int64(window.start.timeIntervalSinceReferenceDate * 1_000_000_000)
        let end = Int64(window.end.timeIntervalSinceReferenceDate * 1_000_000_000)
        let rows: [SQLiteRow]
        do {
            rows = try ReadOnlySQLiteDatabase.query(
                databaseURL,
                sql: """
                SELECT m.ROWID AS row_id, m.date AS message_date,
                       m.is_from_me AS is_from_me, m.text AS text,
                       m.attributedBody AS attributed_body,
                       cmj.chat_id AS chat_id
                FROM message AS m
                JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
                WHERE m.date >= ?1 AND m.date < ?2
                  AND m.service IN ('iMessage', 'SMS', 'RCS')
                  AND IFNULL(m.is_empty, 0) = 0
                  AND IFNULL(m.is_system_message, 0) = 0
                  AND IFNULL(m.item_type, 0) = 0
                  AND IFNULL(m.is_spam, 0) = 0
                  AND IFNULL(m.associated_message_type, 0) = 0
                  AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
                ORDER BY m.date DESC, m.ROWID DESC
                LIMIT 500
                """,
                bindings: [.integer(start), .integer(end)]
            )
        } catch {
            throw map(error)
        }

        // Rows arrive newest-first so the cap keeps the most recent slice of
        // the day. Reading oldest-first instead froze the judge's view at
        // whenever the 80th message of the day landed, which on a busy morning
        // was the middle of the night.
        var seenRows: Set<Int64> = []
        var messages: [Message] = []
        for row in rows {
            guard let rowID = row["row_id"].int64, seenRows.insert(rowID).inserted,
                  let rawDate = row["message_date"].int64,
                  let chatID = row["chat_id"].int64
            else { continue }
            let rawText = row["text"].string
                ?? row["attributed_body"].data.flatMap(Self.textFromAttributedBody)
            guard let rawText,
                  let text = ActivityPrivacySanitizer.text(rawText, limit: 220),
                  text.count >= 2
            else { continue }
            messages.append(Message(
                chatID: chatID,
                date: Date(timeIntervalSinceReferenceDate: Double(rawDate) / 1_000_000_000),
                isFromMe: row["is_from_me"].int64 == 1,
                text: text
            ))
            if messages.count >= 80 { break }
        }

        return Dictionary(grouping: messages, by: \.chatID)
            .compactMap { _, conversation -> WorkActivity? in
                let sorted = conversation.sorted { $0.date < $1.date }
                guard let first = sorted.first, let last = sorted.last else { return nil }
                // The tail of a thread carries the ask ("can you grab milk?");
                // its opening lines are usually stale by check-in time.
                let snippets = sorted.suffix(12).map {
                    "\($0.isFromMe ? "You" : "Reply"): \($0.text)"
                }
                return WorkActivity(
                    source: .messages,
                    summary: "Messages conversation · \(sorted.count) \(sorted.count == 1 ? "message" : "messages")",
                    features: snippets,
                    startedAt: first.date,
                    endedAt: last.date
                )
            }
            .sorted { $0.startedAt < $1.startedAt }
            .suffix(16)
    }

    /// Modern Messages archives sometimes store text only in an attributed
    /// string typedstream. A defensive printable-run extractor avoids unsafe
    /// Objective-C unarchiving (which can raise exceptions for corrupt data).
    static func textFromAttributedBody(_ data: Data) -> String? {
        var chunks: [Data] = []
        var current = Data()
        for byte in data {
            if byte == 9 || byte == 10 || byte == 13 || byte >= 32 {
                current.append(byte)
            } else {
                if current.count >= 3 { chunks.append(current) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= 3 { chunks.append(current) }

        let technical = [
            "streamtyped", "NSAttributedString", "NSMutableAttributedString",
            "NSString", "NSObject", "NSDictionary", "NSFont", "__kIM",
        ]
        return chunks.map {
            String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "�", with: " ")
        }
            .map { candidate in
                technical.reduce(candidate) { result, token in
                    result.replacingOccurrences(of: token, with: " ")
                }
            }
            .compactMap { ActivityPrivacySanitizer.text($0, limit: 220) }
            .filter { candidate in
                candidate.count >= 2 && candidate.unicodeScalars.contains(where: CharacterSet.letters.contains)
            }
            .max { lhs, rhs in lhs.count < rhs.count }
    }

    private func map(_ error: Error) -> ActivitySourceFailure {
        if let sqlite = error as? SQLiteReadError, sqlite.isAccessFailure {
            return .permissionRequired("Allow Manas in Full Disk Access to read Messages.")
        }
        return .readFailed("Messages could not be read right now.")
    }

    private struct Message: Sendable {
        var chatID: Int64
        var date: Date
        var isFromMe: Bool
        var text: String
    }
}
