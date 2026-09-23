import Foundation
import SigilKit
import Testing

@testable import SigilApp

struct SessionBucketTests {
    @Test func futureDatesOutsideClockSkewDoNotReadAsNow() {
        #expect(Date.now.addingTimeInterval(5 * 60).shortRelative != "now")
        #expect(Date.now.addingTimeInterval(30).shortRelative == "now")
    }

    /// A local evening on the last day of a month is still that month, even when
    /// UTC has already rolled over.
    @Test func monthBucketsFollowTheLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        func local(_ month: Int, _ day: Int, _ hour: Int) throws -> Date {
            try #require(
                calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
        }
        let sessions = [
            bucketSession(id: "aug3", updatedAt: try local(8, 3, 12)),
            bucketSession(id: "jul31-evening", updatedAt: try local(7, 31, 20)),
            bucketSession(id: "jul20", updatedAt: try local(7, 20, 12)),
        ]

        let buckets = SessionBucket.bucket(sessions, now: try local(9, 23, 12), calendar: calendar)

        #expect(buckets.map { $0.sessions.map(\.id) } == [["aug3"], ["jul31-evening", "jul20"]])
        #expect(buckets.map(\.title) == ["August 2026", "July 2026"])
    }

    /// East of UTC the early hours of the first of a month are still that month.
    @Test func monthBucketsFollowTheLocalCalendarEastOfUTC() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        func local(_ month: Int, _ day: Int, _ hour: Int) throws -> Date {
            try #require(
                calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
        }
        let sessions = [
            bucketSession(id: "aug1-early", updatedAt: try local(8, 1, 3)),
            bucketSession(id: "jul20", updatedAt: try local(7, 20, 12)),
        ]

        let buckets = SessionBucket.bucket(sessions, now: try local(9, 23, 12), calendar: calendar)

        #expect(buckets.map { $0.sessions.map(\.id) } == [["aug1-early"], ["jul20"]])
        #expect(buckets.map(\.title) == ["August 2026", "July 2026"])
    }
}

private func bucketSession(id: String, updatedAt: Date) -> GrokSession {
    GrokSession(
        id: id,
        cwd: "/tmp/sigil",
        summary: id,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        messageCount: 4,
        modelID: nil,
        agentName: nil,
        reasoningEffort: nil,
        directory: URL(fileURLWithPath: "/tmp/sigil").appendingPathComponent(id)
    )
}
