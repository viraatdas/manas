import Foundation

/// Phone-OTP auth against Supabase's GoTrue endpoints, using plain URLSession
/// so macOS and iOS share one dependency-free client.
struct SupabaseAuthClient: Sendable {
    var baseURL: URL = SupabaseConfig.projectURL
    var anonKey: String = SupabaseConfig.anonKey

    enum AuthError: LocalizedError {
        case server(String)

        var errorDescription: String? {
            switch self {
            case .server(let message): message
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

    /// Trades the refresh token for a fresh session.
    func refresh(_ session: SupabaseSession) async throws -> SupabaseSession {
        let data = try await post(
            path: "auth/v1/token",
            query: "grant_type=refresh_token",
            body: ["refresh_token": session.refreshToken]
        )
        return try Self.session(from: data, fallbackPhone: session.phone)
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
            throw AuthError.server(Self.errorMessage(from: data, status: http.statusCode))
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
