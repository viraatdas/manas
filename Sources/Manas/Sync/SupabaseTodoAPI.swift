import Foundation

/// The `todos` table over PostgREST. Row-level security scopes every call to
/// the signed-in user — plus the shared groups they belong to — so the client
/// never filters by identity itself.
struct SupabaseTodoAPI: Sendable {
    var client = PostgRESTClient()

    typealias APIError = PostgRESTClient.APIError

    /// PostgREST's hard cap per request (`max_rows` in supabase/config.toml).
    static let defaultPageSize = 1000
    /// Smaller in the live test, so the page-to-page cursor is exercised
    /// against the real PostgREST without a thousand rows.
    var pageSize = SupabaseTodoAPI.defaultPageSize

    /// Every row changed since the watermark — all rows when nil — oldest
    /// change first so a later row in the page wins any in-page conflict.
    ///
    /// Reads the whole change set, page by page, before returning. A single
    /// page used to be the pull, and it quietly lost data: a fresh device
    /// with more than a thousand rows on the server took the oldest thousand,
    /// then its own pushes moved the watermark past everything it had not
    /// seen. Pages are keyed on the last row seen — (updated_at, id) — rather
    /// than on an offset, because a row edited elsewhere between two page
    /// fetches moves to the end of the ordering and shifts every later row
    /// up a slot, and an offset then skips one. The pull starts
    /// `SyncMerge.pullOverlap` behind the watermark rather than at it, for
    /// the reason described on `SyncMerge`.
    func changes(since watermark: Date?, accessToken: String) async throws -> [TodoRecord] {
        try await Self.paginate(pageSize: pageSize, floor: SyncMerge.pullFloor(for: watermark)) { query in
            let data = try await client.request(
                method: "GET",
                path: "rest/v1/todos",
                query: query,
                accessToken: accessToken
            )
            return try TodoRecord.makeDecoder().decode([TodoRecord].self, from: data)
        }
    }

    /// The page loop, separated from the transport so it can be driven
    /// against a fake table. Every page is appended whole — a row re-read on
    /// a later page carries its newer content, and the merge keeps the last
    /// occurrence — and the loop ends on a short page or on a page that
    /// brought nothing new.
    static func paginate(
        pageSize: Int,
        floor: Date?,
        isolation: isolated (any Actor)? = #isolation,
        fetch: (String) async throws -> [TodoRecord]
    ) async throws -> [TodoRecord] {
        var all: [TodoRecord] = []
        var seen = Set<UUID>()
        var cursor: TodoRecord?
        for _ in 0..<200 {
            let page = try await fetch(pageQuery(after: cursor, floor: floor, pageSize: pageSize))
            all.append(contentsOf: page)
            let fresh = page.filter { seen.insert($0.id).inserted }.count
            guard page.count >= pageSize, fresh > 0, let last = page.last else { break }
            cursor = last
        }
        return all
    }

    /// One page's query. The first page starts at the floor; every later
    /// page starts after the cursor row on (updated_at, id). The tie clause
    /// uses `gte` rather than `eq` so a stamp that lost precision on the way
    /// through the wire re-reads a few rows instead of skipping any.
    static func pageQuery(after cursor: TodoRecord?, floor: Date?, pageSize: Int) -> String {
        var query = "select=*&order=updated_at.asc,id.asc&limit=\(pageSize)"
        if let cursor {
            let stamp = PostgRESTClient.stamp(cursor.updatedAt)
            let id = cursor.id.uuidString.lowercased()
            query += "&or=(updated_at.gt.\(stamp),and(updated_at.gte.\(stamp),id.gt.\(id)))"
        } else if let floor {
            query += "&updated_at=gt.\(PostgRESTClient.stamp(floor))"
        }
        return query
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
