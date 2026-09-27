import UserNotifications

/// Opens the sealed alert the Mac sent and puts its words on the notification.
/// Invalid or replayed payloads keep only a local, non-actionable fallback.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        handler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content
        // Never preserve routing metadata supplied outside the sealed payload.
        content.userInfo = [:]
        content.title = "Sigil"
        content.subtitle = ""
        content.body = "Open Sigil to check your sessions."
        content.threadIdentifier = ""
        content.sound = nil
        content.badge = nil
        content.interruptionLevel = .passive
        content.categoryIdentifier = ""
        let macs = CredentialStore.loadAll()
        if let sealed = (request.content.userInfo["sigil"] as? [String: Any])?["data"] as? String,
            let opened = RemoteAlert.opened(sealed, keys: macs.map(\.deviceKey)),
            AlertReceiptStore.local?.consume(opened.alert, pairingID: macs[opened.keyIndex].id) == true
        {
            let mac = macs[opened.keyIndex]
            content.sound = .default
            content.interruptionLevel = .active
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
