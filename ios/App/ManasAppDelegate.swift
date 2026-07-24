import UIKit
import FirebaseCore
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
        // Configure HERE, not in App.init: SwiftUI's App struct initializes
        // before UIApplication has a delegate, and Firebase's notification
        // swizzling can only hook a delegate that already exists. Configuring
        // too early is what breaks phone auth's app-verification handshake.
        if FirebaseApp.app() == nil,
           let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
        }
        application.registerForRemoteNotifications()
        return true
    }

    // Explicit forwarding of the notification path to FirebaseAuth. The
    // swizzler is supposed to inject these, but without FirebaseMessaging in
    // the app it doesn't reliably hook APNs methods — and phone auth's
    // verification prober needs them to exist.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if Auth.auth().canHandleNotification(userInfo) {
            completionHandler(.noData)
            return
        }
        completionHandler(.noData)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Simulator or push-less build: phone auth falls back to reCAPTCHA.
    }
}
