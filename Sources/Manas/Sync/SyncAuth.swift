import Foundation

/// The auth backend `SyncController` drives. Two implementations exist because
/// the platforms differ: the Mac uses Supabase's own phone auth (works
/// headlessly, cross-platform HTTP), iOS uses Firebase (real SMS on Google's
/// network, but its phone-auth SDK is iOS-only). Both ultimately yield a bearer
/// token whose phone-number claim keys the same rows, so a number reaches the
/// same todos from either app.
@MainActor
protocol SyncAuth: AnyObject {
    /// A restored session from a previous launch, if any.
    var isSignedIn: Bool { get }
    /// The signed-in phone number, for display.
    var phone: String? { get }

    /// Sends the one-time code.
    func requestCode(phone: String) async throws
    /// Redeems the code, establishing a session.
    func verifyCode(phone: String, code: String) async throws
    /// A currently-valid bearer token for PostgREST (refreshed as needed).
    func bearerToken() async throws -> String
    /// Permanently removes the remote account and all server-side data.
    func deleteAccount() async throws
    func signOut()
}

/// Calls the authenticated account-deletion branch of the sync edge function.
/// The server derives identity from the bearer token; no user identifier from
/// the client is trusted.
struct AccountDeletionClient: Sendable {
    enum DeletionError: LocalizedError {
        case server(String)

        var errorDescription: String? {
            switch self {
            case .server(let message): message
            }
        }
    }

    func delete(accessToken: String) async throws {
        var request = URLRequest(url: SupabaseConfig.stytchAuthURL)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "delete"])

        let (data, response) = try await URLSession.shared.data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = body?["error"] as? String ?? "Account deletion failed. Please try again."
            throw DeletionError.server(message)
        }
    }
}
