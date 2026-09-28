import Foundation
import Darwin

/// A bounded receipt ledger in the notification extension's own sandbox. A file
/// lock serializes separate extension processes. Only pairing IDs, UUIDs and
/// timestamps are stored; no notification words or device keys are persisted.
struct AlertReceiptStore {
    let directory: URL
    static let capacity = 512

    static var local: AlertReceiptStore? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { AlertReceiptStore(directory: $0.appendingPathComponent("AlertReceipts", isDirectory: true)) }
    }

    func consume(_ alert: RemoteAlert, pairingID: String, now: Int = Int(Date().timeIntervalSince1970)) -> Bool {
        guard alert.isFresh(now: now), let id = alert.id, !pairingID.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let descriptor = open(directory.appendingPathComponent("receipts.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
            defer { flock(descriptor, LOCK_UN) }
            let file = directory.appendingPathComponent("receipts.json")
            var receipts: [String: Int] = [:]
            if FileManager.default.fileExists(atPath: file.path) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 131_072 else { return false }
                receipts = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file))
            }
            receipts = receipts.filter { $0.value >= now - 330 }
            let key = "\(pairingID)/\(id)"
            guard receipts[key] == nil, receipts.count < Self.capacity else { return false }
            receipts[key] = now
            let data = try JSONEncoder().encode(receipts)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: file, options: options)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            return true
        } catch {
            return false // No untracked delivery if the receipt cannot be committed.
        }
    }
}
