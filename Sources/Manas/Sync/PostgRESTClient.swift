import Foundation

/// The bearer-token HTTP layer under every table API. Row-level security
/// scopes each call to the signed-in phone number, so the client never filters
/// by identity itself — it just asks for the table and gets its own slice.
struct PostgRESTClient: Sendable {
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

        /// True for a refusal — a policy, constraint, or shape the server will
        /// keep refusing — as opposed to a transport or server fault that a
        /// retry could clear.
        var isRejection: Bool {
            switch self {
            case .server(let status, _): (400..<500).contains(status) && status != 401 && status != 429
            }
        }

        var detail: String {
            switch self {
            case .server(let status, let body): "\(status) \(body.prefix(200))"
            }
        }
    }

    @discardableResult
    func request(
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

    /// A timestamp in the form PostgREST filters accept.
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }
}

/// What came of a push: the rows the server took, and the ones it refused
/// along with what it said about each.
struct PushOutcome: Sendable {
    var accepted: Set<UUID> = []
    var rejected: [UUID: String] = [:]

    static let nothing = PushOutcome()
}

extension PostgRESTClient {
    /// Upserts the batch by primary key. PostgREST applies a batch as one
    /// statement, so a single row the server refuses — a policy, a foreign
    /// key, a uniqueness clash — fails every other row with it, and a client
    /// that keeps sending the same batch never syncs anything again. So a
    /// refused batch is retried one row at a time: what the server will take
    /// lands, and only the row it will not is reported back, by id, with the
    /// server's reason. Transport faults and server errors still throw, since
    /// a retry can clear those and splitting the batch would not help.
    func upsertIsolatingRejections<Record: Encodable & Identifiable & Sendable>(
        _ records: [Record],
        path: String,
        accessToken: String,
        encoder: JSONEncoder
    ) async throws -> PushOutcome where Record.ID == UUID {
        guard !records.isEmpty else { return .nothing }
        let headers = ["Prefer": "resolution=merge-duplicates,return=minimal"]
        do {
            try await request(
                method: "POST", path: path, accessToken: accessToken,
                body: try encoder.encode(records), headers: headers
            )
            return PushOutcome(accepted: Set(records.map(\.id)))
        } catch let error as APIError where error.isRejection && records.count > 1 {
            var outcome = PushOutcome()
            for record in records {
                do {
                    try await request(
                        method: "POST", path: path, accessToken: accessToken,
                        body: try encoder.encode([record]), headers: headers
                    )
                    outcome.accepted.insert(record.id)
                } catch let error as APIError where error.isRejection {
                    outcome.rejected[record.id] = error.detail
                }
            }
            return outcome
        } catch let error as APIError where error.isRejection {
            return PushOutcome(rejected: [records[0].id: error.detail])
        }
    }
}
