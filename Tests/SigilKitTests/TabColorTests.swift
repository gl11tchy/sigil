import Foundation
import Testing

@testable import SigilKit

struct TabColorTests {
    @Test func settingAColorReplacesAndClearingRemovesIt() {
        var records: [TabColorRecord] = []
        records = TabColors.setting(.mint, sessionID: "a", cwd: "/one", onto: records, samePath: ==)
        #expect(TabColors.color(sessionID: "a", cwd: "/one", in: records, samePath: ==) == .mint)

        let again = TabColors.setting(
            .mint, sessionID: "a", cwd: "/one", onto: records, samePath: ==)
        #expect(again == records)

        records = TabColors.setting(.cyan, sessionID: "a", cwd: "/one", onto: records, samePath: ==)
        #expect(records.count == 1)
        #expect(TabColors.color(sessionID: "a", cwd: "/one", in: records, samePath: ==) == .cyan)

        records = TabColors.setting(nil, sessionID: "a", cwd: "/one", onto: records, samePath: ==)
        #expect(records.isEmpty)
    }

    @Test func theSameSessionInAnotherFolderKeepsItsOwnColor() {
        var records: [TabColorRecord] = []
        records = TabColors.setting(
            .mint, sessionID: "same", cwd: "/one", onto: records, samePath: ==)
        records = TabColors.setting(
            .amber, sessionID: "same", cwd: "/two", onto: records, samePath: ==)
        #expect(TabColors.color(sessionID: "same", cwd: "/one", in: records, samePath: ==) == .mint)
        #expect(TabColors.color(sessionID: "same", cwd: "/two", in: records, samePath: ==) == .amber)
        records = TabColors.setting(nil, sessionID: "same", cwd: "/one", onto: records, samePath: ==)
        #expect(TabColors.color(sessionID: "same", cwd: "/two", in: records, samePath: ==) == .amber)
    }

    @Test func decodeSkipsAnUnknownColorAndRejectsGarbage() throws {
        let data = Data(
            #"[{"sessionID":"a","cwd":"/tmp","color":"mint"},{"sessionID":"b","cwd":"/tmp","color":"nope"}]"#
                .utf8)
        let decoded = try #require(TabColors.decode(data))
        #expect(decoded == [TabColorRecord(sessionID: "a", cwd: "/tmp", color: .mint)])
        #expect(TabColors.decode(Data("not-json".utf8)) == nil)
    }

    @Test func turningADifferentMarkOffDoesNotClearTheCurrentColor() {
        #expect(TabColors.choosing(.cyan, isOn: true, current: .mint) == .cyan)
        #expect(TabColors.choosing(.mint, isOn: false, current: .cyan) == .cyan)
        #expect(TabColors.choosing(.mint, isOn: false, current: .mint) == nil)
        #expect(TabColors.choosing(.amber, isOn: false, current: nil) == nil)
    }

    @Test func marksUseTheSigilNeonHues() {
        #expect(TabColor.mint.hex == 0x4EF0C4)
        #expect(TabColor.cyan.hex == 0x5AD9FF)
        #expect(TabColor.violet.hex == 0xA98BFF)
        #expect(TabColor.amber.hex == 0xFFC46B)
        #expect(TabColor.magenta.hex == 0xFF5F9E)
        #expect(TabColor.allCases.map(\.label) == ["Mint", "Cyan", "Violet", "Amber", "Magenta"])
    }
}
