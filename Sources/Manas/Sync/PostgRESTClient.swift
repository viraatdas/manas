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
