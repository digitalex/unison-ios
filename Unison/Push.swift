import OSLog
import SwiftUI
import UIKit
import UserNotifications

/// Where a notification, or a `unison://open?…` link, asks the app to go.
/// Both carry the push payload's keys: `workspace_id`, `message_id`,
/// `parent_id`, `item_id`, `comment_id`.
struct Route: Equatable, Sendable {
    var workspaceID: String?
    var messageID: Int64?
    var parentID: Int64?
    var itemID: Int64?
    var commentID: Int64?

    /// The chat thread to open: the reply's root, or the message itself.
    var thread: Int64? { parentID ?? messageID }

    init?(userInfo: [AnyHashable: Any]) {
        func int(_ key: String) -> Int64? {
            (userInfo[key] as? NSNumber)?.int64Value ?? (userInfo[key] as? String).flatMap { Int64($0) }
        }
        self.init(workspaceID: userInfo["workspace_id"] as? String, messageID: int("message_id"),
                  parentID: int("parent_id"), itemID: int("item_id"), commentID: int("comment_id"))
    }

    init?(url: URL) {
        guard url.scheme == "unison", url.host() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        self.init(workspaceID: value("workspace_id"), messageID: value("message_id").flatMap { Int64($0) },
                  parentID: value("parent_id").flatMap { Int64($0) }, itemID: value("item_id").flatMap { Int64($0) },
                  commentID: value("comment_id").flatMap { Int64($0) })
    }

    private init?(workspaceID: String?, messageID: Int64?, parentID: Int64?, itemID: Int64?, commentID: Int64?) {
        guard messageID != nil || itemID != nil else { return nil }
        self.workspaceID = workspaceID
        self.messageID = messageID
        self.parentID = parentID
        self.itemID = itemID
        self.commentID = commentID
    }
}

/// Owns the app model and connects it to push notifications: device
/// registration, and taps on notifications.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // Simulates opening a notification or link at launch: UNISON_ROUTE=unison://open?…
        if let s = ProcessInfo.processInfo.environment["UNISON_ROUTE"], let url = URL(string: s) {
            model.route = Route(url: url)
        }
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await model.registerDevice(hex) }
    }

    /// A silent push (#122): chat was read elsewhere up to `read_up_to`, so
    /// clear the notifications for those messages.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard userInfo["kind"] as? String == "read", let ws = userInfo["workspace_id"] as? String,
              let upTo = (userInfo["read_up_to"] as? NSNumber)?.int64Value else {
            completionHandler(.noData)
            return
        }
        log.info("read: push for \(ws, privacy: .public) up to \(upTo)")
        nonisolated(unsafe) let done = completionHandler
        Task {
            await ReadMarker.clear(workspace: ws, upTo: upTo)
            done(.newData)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("push: registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // These use the completion-handler forms: the async ones return off the
    // main thread, and UIKit then aborts ("Call must be made on main thread")
    // when a tap launches the app.

    // Show notifications while the app is open, too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = Route(userInfo: response.notification.request.content.userInfo)
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let route { self.model.route = route }
                done()
            }
        }
    }
}
