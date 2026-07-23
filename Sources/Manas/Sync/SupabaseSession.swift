import Foundation

/// An authenticated Supabase session. Persisted to the keychain so sign-in
/// survives relaunches; refreshed via the refresh token when the access token
/// nears expiry.
struct SupabaseSession: Codable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    /// E.164 phone the user signed in with, for display ("+14155550137").
    var phone: String

    /// Refresh slightly early so an in-flight request never carries a token
    /// that expires mid-call.
    var needsRefresh: Bool {
        Date() > expiresAt.addingTimeInterval(-60)
    }
}
