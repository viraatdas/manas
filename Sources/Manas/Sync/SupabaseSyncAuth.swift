import Foundation

/// Supabase phone-OTP auth — the Mac's backend, and the fallback everywhere
/// Firebase isn't wired up. Holds the GoTrue session, persists it in the
/// keychain, and refreshes the access token when it nears expiry.
@MainActor
final class SupabaseSyncAuth: SyncAuth {
    private let client = SupabaseAuthClient()
    private var session: SupabaseSession?
    private static let account = "session"

    init() {
        if let data = KeychainStore.load(account: Self.account),
           let saved = try? JSONDecoder().decode(SupabaseSession.self, from: data) {
            session = saved
        }
    }

    var isSignedIn: Bool { session != nil }
    var phone: String? { session?.phone }

    func requestCode(phone: String) async throws {
        try await client.requestCode(phone: phone)
    }

    func verifyCode(phone: String, code: String) async throws {
        store(try await client.verifyCode(phone: phone, code: code))
    }

    func bearerToken() async throws -> String {
        guard var current = session else {
            throw SupabaseAuthClient.AuthError.server("Signed out.")
        }
        if current.needsRefresh {
            current = try await client.refresh(current)
            store(current)
        }
        return current.accessToken
    }

    func signOut() {
        session = nil
        KeychainStore.delete(account: Self.account)
    }

    private func store(_ new: SupabaseSession) {
        session = new
        if let data = try? JSONEncoder().encode(new) {
            KeychainStore.save(data, account: Self.account)
        }
    }
}
