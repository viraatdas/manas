import Foundation

/// The `todos` table over PostgREST. Row-level security scopes every call to
/// the signed-in user — plus the shared groups they belong to — so the client
/// never filters by identity itself.
struct SupabaseTodoAPI: Sendable {
    var client = PostgRESTClient()

    typealias APIError = PostgRESTClient.APIError

    /// PostgREST's hard cap per request (`max_rows` in supabase/config.toml).
    static let pageSize = 1000

    /// Every row changed since the watermark — all rows when nil — oldest
    /// change first so a later row in the page wins any in-page conflict.
    ///
    /// Reads the whole change set, page by page, before returning. A single
    /// page used to be the pull, and it quietly lost data: a fresh device
    /// with more than a thousand rows on the server took the oldest thousand,
    /// then its own pushes moved the watermark past everything it had not
    /// seen. And the pull starts `SyncMerge.pullOverlap` behind the watermark
    /// rather than at it, for the reason described on `SyncMerge`.
    func changes(since watermark: Date?, accessToken: String) async throws -> [TodoRecord] {
        var all: [TodoRecord] = []
        var offset = 0
        while true {
            var query = "select=*&order=updated_at.asc,id.asc&limit=\(Self.pageSize)&offset=\(offset)"
            if let floor = SyncMerge.pullFloor(for: watermark) {
                query += "&updated_at=gt.\(PostgRESTClient.stamp(floor))"
            }
            let data = try await client.request(
                method: "GET",
                path: "rest/v1/todos",
                query: query,
                accessToken: accessToken
            )
            let page = try TodoRecord.makeDecoder().decode([TodoRecord].self, from: data)
            all.append(contentsOf: page)
            guard page.count == Self.pageSize else { break }
            offset += Self.pageSize
            // A ceiling well above any real list, so a server that somehow
            // keeps answering full pages cannot hold the pass open forever.
            guard offset < 100 * Self.pageSize else { break }
        }
        return all
    }

    /// Upserts the batch by primary key — inserts new rows, overwrites
    /// changed ones (including tombstones). Throws on any refusal; the
    /// sync loop uses `push` instead so one bad row cannot block the rest.
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

    /// Pushes what the server will take and reports what it refused.
    func push(_ records: [TodoRecord], accessToken: String) async throws -> PushOutcome {
        try await client.upsertIsolatingRejections(
            records,
            path: "rest/v1/todos",
            accessToken: accessToken,
            encoder: TodoRecord.makeEncoder()
        )
    }
}
