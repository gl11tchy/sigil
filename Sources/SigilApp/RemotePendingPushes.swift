import Foundation

/// Only push frames wait here. Event bytes, time and expiry never change when
/// a connection is replaced or a drain resumes.
struct RemotePendingPushes {
    enum Kind: Equatable { case alert, update, end }
    struct Entry {
        let id = UUID()
        let frame: RemoteControl.Frame
        let kind: Kind
        let tabID: String
        let pairing: UUID
        var room: String?
        let tokenGeneration: UUID
        let environment: String?
        let issuedAt: Date
        let expiresAt: Date
    }
    static let capacity = 20
    private(set) var entries: [Entry] = []

    mutating func append(_ entry: Entry, now: Date) -> Bool {
        expire(now: now)
        guard entry.expiresAt > now else { return false }
        if entry.kind == .update {
            if entries.contains(where: {
                $0.kind == .end && $0.tabID == entry.tabID && $0.tokenGeneration == entry.tokenGeneration
            }) {
                return false
            }
            entries.removeAll {
                $0.kind == .update && $0.tabID == entry.tabID && $0.tokenGeneration == entry.tokenGeneration
            }
        } else if entry.kind == .end {
            entries.removeAll {
                $0.kind == .update && $0.tabID == entry.tabID && $0.tokenGeneration == entry.tokenGeneration
            }
            if entries.contains(where: {
                $0.kind == .end && $0.tabID == entry.tabID && $0.tokenGeneration == entry.tokenGeneration
            }) {
                return true
            }
        }
        if entries.count == Self.capacity {
            guard let discarded = entries.firstIndex(where: { $0.kind != .end }) else { return false }
            entries.remove(at: discarded)
        }
        entries.append(entry)
        return true
    }

    mutating func expire(now: Date) { entries.removeAll { $0.expiresAt <= now } }
    mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    mutating func clearAlerts() { entries.removeAll { $0.kind == .alert } }
    mutating func removeActivity(_ tabID: String) { entries.removeAll { $0.kind != .alert && $0.tabID == tabID } }
    mutating func clear() { entries.removeAll() }
}
