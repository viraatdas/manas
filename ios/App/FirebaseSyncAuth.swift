import Foundation
import FirebaseCore
import FirebaseAuth

/// iOS auth backend: Firebase phone-OTP. Firebase sends the SMS on Google's
/// network (no Twilio) and persists its own session, so this only bridges the
/// four calls `SyncController` needs. Registered test numbers skip SMS and app
/// verification entirely; real numbers use APNs or Firebase's reCAPTCHA
/// fallback. The bearer it returns is a Firebase ID token, which Supabase
/// accepts as a third-party provider and whose phone-number claim keys the rows.
@MainActor
final class FirebaseSyncAuth: SyncAuth {
    private var verificationID: String?
    private var isConfigured: Bool { FirebaseApp.app() != nil }

    var isSignedIn: Bool { isConfigured && Auth.auth().currentUser != nil }
    var phone: String? { isConfigured ? Auth.auth().currentUser?.phoneNumber : nil }

    func requestCode(phone: String) async throws {
        guard isConfigured else { throw AuthError.unavailable }
        verificationID = try await PhoneAuthProvider.provider().verifyPhoneNumber(phone, uiDelegate: nil)
    }

    func verifyCode(phone: String, code: String) async throws {
        guard isConfigured else { throw AuthError.unavailable }
        guard let verificationID else { throw AuthError.noCodeRequested }
        let credential = PhoneAuthProvider.provider()
            .credential(withVerificationID: verificationID, verificationCode: code)
        _ = try await Auth.auth().signIn(with: credential)
        self.verificationID = nil
    }

    func bearerToken() async throws -> String {
        guard isConfigured, let user = Auth.auth().currentUser else { throw AuthError.signedOut }
        return try await user.getIDToken()
    }

    func signOut() {
        if isConfigured { try? Auth.auth().signOut() }
        verificationID = nil
    }

    enum AuthError: LocalizedError {
        case unavailable, noCodeRequested, signedOut
        var errorDescription: String? {
            switch self {
            case .unavailable: "Sign-in isn't available in this build."
            case .noCodeRequested: "Request a code first."
            case .signedOut: "You're signed out."
            }
        }
    }
}
