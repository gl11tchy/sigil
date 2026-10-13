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
        let appended1 = queue.append(original, now: now)
        #expect(appended1)
        let copy = try #require(queue.entries.first)
        #expect(copy.id == original.id && copy.issuedAt == now && copy.expiresAt == original.expiresAt)
        #expect(try JSONEncoder().encode(copy.frame) == JSONEncoder().encode(original.frame))
        queue.expire(now: now.addingTimeInterval(299))
        #expect(queue.entries.count == 1)
        queue.expire(now: original.expiresAt)
        #expect(queue.entries.isEmpty)
        let appended2 = queue.append(original, now: original.expiresAt.addingTimeInterval(1))
        #expect(!appended2)
    }

    @Test func latestActivityUpdateCoalescesAndAnEndCannotBeResurrected() {
        var queue = RemotePendingPushes()
        let old = entry(.update, tab: "one")
        let newest = entry(.update, tab: "one", offset: 1)
        let appended3 = queue.append(old, now: now)
        #expect(appended3)
        let appended4 = queue.append(newest, now: now)
        #expect(appended4)
        #expect(queue.entries.count == 1 && queue.entries.first?.id == newest.id)
        let end = entry(.end, tab: "one", offset: 2)
        let appended5 = queue.append(end, now: now)
        #expect(appended5)
        #expect(queue.entries.count == 1 && queue.entries.first?.id == end.id)
        let appended6 = queue.append(entry(.update, tab: "one", offset: 3), now: now)
        #expect(!appended6)
        let appended7 = queue.append(entry(.end, tab: "one", offset: 4), now: now)
        #expect(appended7)
        #expect(queue.entries.first?.id == end.id)
    }

    @Test func capacityEvictsOrdinaryEventsAndPreservesReservedEnds() {
        var queue = RemotePendingPushes()
        for index in 0..<RemotePendingPushes.capacity {
            let appended8 = queue.append(entry(.alert, tab: "\(index)"), now: now)
            #expect(appended8)
        }
        let end = entry(.end, tab: "closed")
        let appended9 = queue.append(end, now: now)
        #expect(appended9)
        #expect(queue.entries.count == RemotePendingPushes.capacity)
        #expect(queue.entries.contains { $0.id == end.id })
        for index in 1..<RemotePendingPushes.capacity {
            let appended10 = queue.append(entry(.end, tab: "closed-\(index)"), now: now)
            #expect(appended10)
        }
        #expect(queue.entries.allSatisfy { $0.kind == .end })
        let appended11 = queue.append(entry(.alert, tab: "new"), now: now)
        #expect(!appended11)
        #expect(queue.entries.count == RemotePendingPushes.capacity)
    }

    @Test func authenticatedAlertClearRetainsActivitiesUntilExplicitReconciliation() {
        var queue = RemotePendingPushes()
        let appended12 = queue.append(entry(.alert, tab: "one"), now: now)
        #expect(appended12)
        let appended13 = queue.append(entry(.update, tab: "two"), now: now)
        #expect(appended13)
        let end = entry(.end, tab: "closed")
        let appended14 = queue.append(end, now: now)
        #expect(appended14)
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
