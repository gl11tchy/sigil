import UserNotifications

/// Opens the sealed alert the Mac sent and puts its words on the notification.
/// Without a matching key the notification keeps the relay's plain fallback.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        handler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content
        let keys = CredentialStore.loadAll().map(\.deviceKey)
        if let sealed = (request.content.userInfo["sigil"] as? [String: Any])?["data"] as? String,
            let alert = RemoteAlert.open(sealed, keys: keys)
        {
            content.title = alert.title
            content.body = alert.shownBody
            content.threadIdentifier = alert.tabID
            content.userInfo["tabID"] = alert.tabID
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
    }
}
