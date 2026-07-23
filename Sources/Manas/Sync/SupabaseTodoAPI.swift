import Foundation

/// The `todos` table over PostgREST. Row-level security scopes every call to
/// the signed-in user, so the client never filters by user id itself.
struct SupabaseTodoAPI: Sendable {
    var baseURL: URL = SupabaseConfig.projectURL
    var anonKey: String = SupabaseConfig.anonKey

    enum APIError: LocalizedError {
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .server:
                "Sync couldn’t finish. Manas will retry automatically."
            }
        }
    }

    /// Rows changed since `watermark` (all rows when nil), oldest change first
    /// so a later row in the page wins any in-page conflict naturally.
    func changes(since watermark: Date?, accessToken: String) async throws -> [TodoRecord] {
        var query = "select=*&order=updated_at.asc&limit=1000"
        if let watermark {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = formatter.string(from: watermark)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            query += "&updated_at=gt.\(stamp)"
        }
        let data = try await request(
            method: "GET",
            path: "rest/v1/todos",
            query: query,
            accessToken: accessToken
        )
        return try TodoRecord.makeDecoder().decode([TodoRecord].self, from: data)
    }

    /// Upserts the batch by primary key — inserts new rows, overwrites
    /// changed ones (including tombstones).
    func upsert(_ records: [TodoRecord], accessToken: String) async throws {
        guard !records.isEmpty else { return }
        _ = try await request(
            method: "POST",
            path: "rest/v1/todos",
            accessToken: accessToken,
            body: try TodoRecord.makeEncoder().encode(records),
            headers: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )
    }

    private func request(
        method: String,
        path: String,
        query: String? = nil,
        accessToken: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var url = baseURL.appendingPathComponent(path)
        if let query {
            url = URL(string: "\(url.absoluteString)?\(query)") ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server(0, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
