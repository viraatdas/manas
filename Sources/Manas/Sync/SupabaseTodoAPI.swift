import Foundation

/// The `todos` table over PostgREST. Row-level security scopes every call to
/// the signed-in user — plus the shared groups they belong to — so the client
/// never filters by identity itself.
struct SupabaseTodoAPI: Sendable {
    var client = PostgRESTClient()

    typealias APIError = PostgRESTClient.APIError

    /// Rows changed since `watermark` (all rows when nil), oldest change first
    /// so a later row in the page wins any in-page conflict naturally.
    func changes(since watermark: Date?, accessToken: String) async throws -> [TodoRecord] {
        var query = "select=*&order=updated_at.asc&limit=1000"
        if let watermark {
            query += "&updated_at=gt.\(PostgRESTClient.stamp(watermark))"
        }
        let data = try await client.request(
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
        try await client.request(
            method: "POST",
            path: "rest/v1/todos",
            accessToken: accessToken,
            body: try TodoRecord.makeEncoder().encode(records),
            headers: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )
    }
}
