import Foundation

/// The `shared_groups` and `shared_group_members` tables over PostgREST.
///
/// Both are pulled whole rather than by watermark: a person is in a handful of
/// shared groups with a handful of people each, so the page is tiny, and a
/// full pull is what makes a revoked share disappear without needing its own
/// change feed.
struct SupabaseShareAPI: Sendable {
    var client = PostgRESTClient()

    /// Every share the signed-in number owns or belongs to.
    func groups(accessToken: String) async throws -> [SharedGroupRecord] {
        let data = try await client.request(
            method: "GET",
            path: "rest/v1/shared_groups",
            query: "select=*&order=created_at.asc&limit=500",
            accessToken: accessToken
        )
        return try TodoRecord.makeDecoder().decode([SharedGroupRecord].self, from: data)
    }

    /// Every membership row of every share the signed-in number can see.
    func members(accessToken: String) async throws -> [SharedGroupMemberRecord] {
        let data = try await client.request(
            method: "GET",
            path: "rest/v1/shared_group_members",
            query: "select=*&order=created_at.asc&limit=2000",
            accessToken: accessToken
        )
        return try TodoRecord.makeDecoder().decode([SharedGroupMemberRecord].self, from: data)
    }

    func upsertGroups(_ records: [SharedGroupRecord], accessToken: String) async throws {
        guard !records.isEmpty else { return }
        try await client.request(
            method: "POST",
            path: "rest/v1/shared_groups",
            accessToken: accessToken,
            body: try TodoRecord.makeEncoder().encode(records),
            headers: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )
    }

    func upsertMembers(_ records: [SharedGroupMemberRecord], accessToken: String) async throws {
        guard !records.isEmpty else { return }
        try await client.request(
            method: "POST",
            path: "rest/v1/shared_group_members",
            accessToken: accessToken,
            body: try TodoRecord.makeEncoder().encode(records),
            headers: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )
    }
}
