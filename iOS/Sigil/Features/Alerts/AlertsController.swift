import SwiftUI
import UIKit
import UserNotifications

/// Asks for notification permission once the phone is paired, hands the APNs
/// token to the store, and turns a tapped notification into a session choice.
/// A notification only navigates; it never sends a keystroke.
final class AlertsController: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the app scene once the store exists; the delegate is made earlier.
    static weak var store: RemoteStore?
    private static var pendingToken: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Requests permission and registers. Safe to call more than once.
    @MainActor
    static func enable() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            if let store = Self.store { store.setPushToken(token) } else { Self.pendingToken = token }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Without a token the app still works; alerts are simply off until the next launch tries again.
    }

    /// Called by the scene after the store exists, so a token that arrived first is not lost.
    @MainActor
    static func attach(_ store: RemoteStore) {
        Self.store = store
        if let token = pendingToken {
            pendingToken = nil
            store.setPushToken(token)
        }
    }

    /// The app is open: show the banner anyway, the session may not be the one on screen.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let tabID = response.notification.request.content.userInfo["tabID"] as? String else { return }
        await MainActor.run { Self.store?.open(tabID: tabID) }
    }

    /// The environment APNs will deliver to, which is what the relay has to be told.
    static var pushEnvironment: String {
        #if DEBUG
            return "development"
        #else
            return "production"
        #endif
    }
}
