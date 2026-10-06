import Foundation

/// Phone-OTP auth against Supabase's GoTrue endpoints, using plain URLSession
/// so macOS and iOS share one dependency-free client.
struct SupabaseAuthClient: Sendable {
    var baseURL: URL = SupabaseConfig.projectURL
    var anonKey: String = SupabaseConfig.anonKey

    enum AuthError: LocalizedError {
        case server(String)
        /// The server answered, and said no. `code` is GoTrue's `error_code`.
        case rejected(status: Int, code: String?, message: String)

        var errorDescription: String? {
            switch self {
            case .server(let message), .rejected(_, _, let message): message
            }
        }
    }

    /// Asks the backend to send a one-time code to `phone` (E.164, "+1...").
    func requestCode(phone: String) async throws {
        _ = try await post(path: "auth/v1/otp", body: ["phone": phone])
    }

    /// Exchanges the received code for a session.
    func verifyCode(phone: String, code: String) async throws -> SupabaseSession {
        let data = try await post(
            path: "auth/v1/verify",
            body: ["phone": phone, "token": code, "type": "sms"]
        )
        return try Self.session(from: data, fallbackPhone: phone)
    }

    /// Trades the refresh token for a fresh session. Throws
    /// `SessionEndedError` when the server refuses the token itself.
    func refresh(_ session: SupabaseSession) async throws -> SupabaseSession {
        let data: Data
        do {
            data = try await post(
                path: "auth/v1/token",
                query: "grant_type=refresh_token",
                body: ["refresh_token": session.refreshToken]
            )
        } catch AuthError.rejected(_, let code, let message) where Self.endsSession(code: code) {
            throw SessionEndedError(reason: message)
        }
        return try Self.session(from: data, fallbackPhone: session.phone)
    }

    /// The refresh refusals that mean the session itself is gone. Keyed on the
    /// server's reason rather than the status: a retired API key, a proxy, or
    /// a rate limit also answers 4xx, and signing every device out over one of
    /// those would cost a needless SMS sign-in for a session that still works.
    static let sessionEndingCodes: Set<String> = [
        "refresh_token_not_found",
        "refresh_token_already_used",
        "session_not_found",
        "session_expired",
        "user_not_found",
        "user_banned",
    ]

    static func endsSession(code: String?) -> Bool {
        code.map(sessionEndingCodes.contains) ?? false
    }

    // MARK: - Wire format

    private struct TokenResponse: Decodable {
        struct User: Decodable {
            var id: String
            var phone: String?
        }

        var accessToken: String
        var refreshToken: String
        var expiresIn: Double
        var user: User

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case user
        }
    }

    private static func session(from data: Data, fallbackPhone: String) throws -> SupabaseSession {
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        var phone = response.user.phone ?? fallbackPhone
        if !phone.hasPrefix("+") { phone = "+\(phone)" }
        return SupabaseSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            userID: response.user.id,
            phone: phone
        )
    }

    private func post(path: String, query: String? = nil, body: [String: String]) async throws -> Data {
        var url = baseURL.appendingPathComponent(path)
        if let query {
            url = URL(string: "\(url.absoluteString)?\(query)") ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.server("No response from the sync server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw AuthError.rejected(
                status: http.statusCode,
                code: object?["error_code"] as? String,
                message: Self.errorMessage(from: data, status: http.statusCode)
            )
        }
        return data
    }

    /// GoTrue errors arrive as {"msg": ...} or {"error_description": ...};
    /// surface whichever is present, sentence-cased for the UI.
    private static func errorMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["msg", "error_description", "message", "error"] {
                if let message = object[key] as? String, !message.isEmpty {
                    return message
                }
            }
        }
        return "Sign-in failed (server returned \(status))."
    }
}
