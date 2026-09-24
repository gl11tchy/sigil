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
        let macs = CredentialStore.loadAll()
        if let sealed = (request.content.userInfo["sigil"] as? [String: Any])?["data"] as? String,
            let opened = RemoteAlert.opened(sealed, keys: macs.map(\.deviceKey))
        {
            let mac = macs[opened.keyIndex]
            content.title = alert(opened.alert, from: mac, among: macs)
            content.body = opened.alert.shownBody
            content.threadIdentifier = "\(mac.id)/\(opened.alert.tabID)"
            content.userInfo["tabID"] = opened.alert.tabID
            content.userInfo["macID"] = mac.id
        }
        contentHandler(content)
    }

    /// With more than one Mac the title says which one.
    private func alert(_ alert: RemoteAlert, from mac: PairingCredential, among macs: [PairingCredential]) -> String {
        macs.count > 1 ? "\(alert.title) · \(mac.label)" : alert.title
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
    }
}
