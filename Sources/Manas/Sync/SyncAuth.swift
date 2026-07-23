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
    func signOut()
}
