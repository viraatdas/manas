import UIKit
import FirebaseAuth

/// Firebase phone auth verifies the app through the UIApplicationDelegate's
/// remote-notification path — including a self-test "prober" sent before any
/// real push. A pure-SwiftUI app has no delegate for Firebase's swizzling to
/// hook, so we supply one; Firebase then forwards the verification
/// notification automatically. Registering for remote notifications lets a real
/// device supply an APNs token for silent verification (the simulator falls
/// back to reCAPTCHA). Without this, phone auth fails with error 17054.
final class ManasAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
}
