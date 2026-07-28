import Foundation

/// iOS auth backend: phone OTP delivered by Stytch. The app talks only to the
/// `stytch-auth` edge function — never to Stytch directly — so the Stytch
/// secret stays server-side. On verify the function returns a genuine Supabase
/// session, which this stores and refreshes exactly like the native flow, so
/// the todo sync layer is unchanged. Stytch is a pure API: no web view is ever
/// presented, so sign-in cannot redirect through a browser.
@MainActor
final class StytchSyncAuth: SyncAuth {
    private let refresher = SupabaseAuthClient()
    private var session: SupabaseSession?
    /// The Stytch method id from the last `requestCode`, needed to redeem the
    /// code. Not a secret — just an identifier.
    private var methodID: String?
    private static let account = "session"

    init() {
        if let data = KeychainStore.load(account: Self.account),
           let saved = try? JSONDecoder().decode(SupabaseSession.self, from: data) {
            session = saved
        }
    }

    var isSignedIn: Bool { session != nil }
    var phone: String? { session?.phone }

    enum AuthError: LocalizedError {
        case server(String)
        case noCodeRequested

        var errorDescription: String? {
            switch self {
            case .server(let message): message
            case .noCodeRequested: "Request a code first."
            }
        }
    }

    func requestCode(phone: String) async throws {
        let body = try await call(["action": "send", "phone": phone])
        guard let id = body["method_id"] as? String else {
            throw AuthError.server(Self.message(body) ?? "Couldn't send the code.")
        }
        methodID = id
    }

    func verifyCode(phone: String, code: String) async throws {
        guard let methodID else { throw AuthError.noCodeRequested }
        let body = try await call([
            "action": "verify", "phone": phone, "method_id": methodID, "code": code,
        ])
        guard let raw = body["session"] as? [String: Any] else {
            throw AuthError.server(Self.message(body) ?? "That code didn't match.")
        }
        session = try Self.session(from: raw, phone: phone)
        self.methodID = nil
        persist()
    }

    func bearerToken() async throws -> String {
        guard var current = session else { throw AuthError.server("Signed out.") }
        if current.needsRefresh {
            current = try await refresher.refresh(current)
            session = current
            persist()
        }
        return current.accessToken
    }

    func deleteAccount() async throws {
        let token = try await bearerToken()
        try await AccountDeletionClient().delete(accessToken: token)
        signOut()
    }

    func signOut() {
        session = nil
        methodID = nil
        KeychainStore.delete(account: Self.account)
    }

    // MARK: - Helpers

    private func persist() {
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        KeychainStore.save(data, account: Self.account)
    }

    private func call(_ payload: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: SupabaseConfig.stytchAuthURL)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.server(Self.message(object) ?? "Sign-in failed (\(http.statusCode)).")
        }
        return object
    }

    private static func message(_ body: [String: Any]) -> String? {
        (body["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func session(from raw: [String: Any], phone: String) throws -> SupabaseSession {
        guard let access = raw["access_token"] as? String,
              let refresh = raw["refresh_token"] as? String
        else { throw AuthError.server("The session was incomplete.") }
        let expiresIn = (raw["expires_in"] as? Double) ?? 3600
        let user = raw["user"] as? [String: Any]
        var resolvedPhone = (user?["phone"] as? String) ?? phone
        if !resolvedPhone.hasPrefix("+") { resolvedPhone = "+\(resolvedPhone)" }
        return SupabaseSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            userID: (user?["id"] as? String) ?? "",
            phone: resolvedPhone
        )
    }
}
