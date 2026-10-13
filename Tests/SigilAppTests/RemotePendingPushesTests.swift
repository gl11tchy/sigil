import Foundation
import Testing

@testable import SigilApp

@MainActor
struct RemotePendingPushesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let pairing = UUID()
    let token = UUID()

    @Test func retriesKeepIdentityBytesIssueTimeAndFixedExpiry() throws {
        var queue = RemotePendingPushes()
        let original = entry(.alert, tab: "one")
        #expect(queue.append(original, now: now))
        let copy = try #require(queue.entries.first)
        #expect(copy.id == original.id && copy.issuedAt == now && copy.expiresAt == original.expiresAt)
        #expect(try JSONEncoder().encode(copy.frame) == JSONEncoder().encode(original.frame))
        queue.expire(now: now.addingTimeInterval(299))
        #expect(queue.entries.count == 1)
        queue.expire(now: original.expiresAt)
        #expect(queue.entries.isEmpty)
        #expect(!queue.append(original, now: original.expiresAt.addingTimeInterval(1)))
    }

    @Test func latestActivityUpdateCoalescesAndAnEndCannotBeResurrected() {
        var queue = RemotePendingPushes()
        let old = entry(.update, tab: "one")
        let newest = entry(.update, tab: "one", offset: 1)
        #expect(queue.append(old, now: now))
        #expect(queue.append(newest, now: now))
        #expect(queue.entries.count == 1 && queue.entries.first?.id == newest.id)
        let end = entry(.end, tab: "one", offset: 2)
        #expect(queue.append(end, now: now))
        #expect(queue.entries.count == 1 && queue.entries.first?.id == end.id)
        #expect(!queue.append(entry(.update, tab: "one", offset: 3), now: now))
        #expect(queue.append(entry(.end, tab: "one", offset: 4), now: now))
        #expect(queue.entries.first?.id == end.id)
    }

    @Test func capacityEvictsOrdinaryEventsAndPreservesReservedEnds() {
        var queue = RemotePendingPushes()
        for index in 0..<RemotePendingPushes.capacity {
            #expect(queue.append(entry(.alert, tab: "\(index)"), now: now))
        }
        let end = entry(.end, tab: "closed")
        #expect(queue.append(end, now: now))
        #expect(queue.entries.count == RemotePendingPushes.capacity)
        #expect(queue.entries.contains { $0.id == end.id })
        for index in 1..<RemotePendingPushes.capacity {
            #expect(queue.append(entry(.end, tab: "closed-\(index)"), now: now))
        }
        #expect(queue.entries.allSatisfy { $0.kind == .end })
        #expect(!queue.append(entry(.alert, tab: "new"), now: now))
        #expect(queue.entries.count == RemotePendingPushes.capacity)
    }

    @Test func authenticatedAlertClearRetainsActivitiesUntilExplicitReconciliation() {
        var queue = RemotePendingPushes()
        #expect(queue.append(entry(.alert, tab: "one"), now: now))
        #expect(queue.append(entry(.update, tab: "two"), now: now))
        let end = entry(.end, tab: "closed")
        #expect(queue.append(end, now: now))
        queue.clearAlerts()
        #expect(queue.entries.map(\.kind) == [.update, .end])
        queue.removeActivity("closed")
        #expect(queue.entries.map(\.kind) == [.update])
        queue.clear()
        #expect(queue.entries.isEmpty)
    }

    private func entry(_ kind: RemotePendingPushes.Kind, tab: String, offset: TimeInterval = 0)
        -> RemotePendingPushes.Entry
    {
        let issued = now.addingTimeInterval(offset)
        return .init(
            frame: .init(push: .init(data: "AAAA", thread: tab)), kind: kind, tabID: tab,
            pairing: pairing, room: "room-one", tokenGeneration: token, environment: "development",
            issuedAt: issued, expiresAt: issued.addingTimeInterval(300))
    }
}
