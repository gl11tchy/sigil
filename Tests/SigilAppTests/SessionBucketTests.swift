import Foundation
import Testing

@testable import SigilApp

struct SessionBucketTests {
    @Test func futureDatesOutsideClockSkewDoNotReadAsNow() {
        #expect(Date.now.addingTimeInterval(5 * 60).shortRelative != "now")
        #expect(Date.now.addingTimeInterval(30).shortRelative == "now")
    }
}
