import UIKit
import UserNotifications

/// Minimal app delegate, attached via `@UIApplicationDelegateAdaptor`, solely to handle local
/// notifications: present the "Update Available" banner while the app is foreground (the update
/// check runs at launch) and open the App Store when it's tapped.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Brings back a rest that was counting down when the app last closed, so
        // it ends with its haptic even if the workout log is never opened.
        _ = WorkoutRestTimerController.shared
        QuickActionSettings.registerApplicationShortcuts()
        WatchSnapshotSync.shared.activate()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    // Retained for iOS versions/configurations that still deliver shortcuts to the app delegate.
    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(QuickActionCoordinator.handle(shortcutItem))
    }

    /// Show the update banner even when the app is in the foreground; leave the scheduled reminders
    /// to their default (no foreground interruption) so this changes nothing for them. A rest
    /// notification shows only when the app did not already mark that rest's end with a haptic.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.identifier == NotificationManager.appUpdateNotificationID
            || notification.request.identifier == NotificationManager.productHuntLaunchNotificationID {
            return [.banner, .sound, .list]
        }
        if notification.request.identifier == WorkoutRestTimerController.notificationID {
            let userInfo = notification.request.content.userInfo
            return WorkoutRestTimerController.shared.presentsNotificationInForeground(userInfo: userInfo)
                ? [.banner, .sound, .list]
                : []
        }
        return []
    }

    /// Open the App Store listing (update) or the linked page (Product Hunt launch) on tap.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let urlString = (userInfo["updateURL"] ?? userInfo["openURL"]) as? String
        if let urlString, let url = URL(string: urlString) {
            await UIApplication.shared.open(url)
        }
    }
}
