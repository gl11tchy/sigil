import Foundation
import Testing

@testable import SigilKit

struct RemoteAlertTests {
    private func snap(_ status: String, question: String? = nil, title: String = "sigil") -> RemoteAlertPlanner.Snapshot
    {
        RemoteAlertPlanner.Snapshot(status: status, since: 100, question: question, title: title)
    }

    @Test func transitionsTable() {
        let table: [(from: String, to: String, kind: RemoteAlert.Kind?)] = [
            ("working", "idle", .finished),
            ("working", "exited", .ended),
            ("idle", "exited", .ended),
            ("starting", "idle", nil),
            ("idle", "working", nil),
            ("idle", "idle", nil),
            ("exited", "exited", nil),
        ]
        for row in table {
            var planner = RemoteAlertPlanner()
            #expect(planner.plan(tabID: "T", snap(row.from)).alert == nil, "first sighting sends nothing")
            let plan = planner.plan(tabID: "T", snap(row.to))
            #expect(plan.alert?.kind == row.kind, "\(row.from) → \(row.to)")
            #expect(plan.activity?.status == (row.from == row.to ? nil : row.to), "\(row.from) → \(row.to) activity")
            #expect(plan.ends == (row.from != row.to && row.to == "exited"), "\(row.from) → \(row.to) ends")
        }
    }

    @Test func aQuestionRaisesOneAlertUntilItGoes() {
        var planner = RemoteAlertPlanner()
        _ = planner.plan(tabID: "T", snap("idle"))
        let asked = planner.plan(tabID: "T", snap("idle", question: "Do you want to proceed?"))
        #expect(asked.alert?.kind == .asking)
        #expect(asked.alert?.body == "Do you want to proceed?")
        #expect(asked.activity?.asking == true)
        let still = planner.plan(tabID: "T", snap("idle", question: "Do you want to proceed?"))
        #expect(still.alert == nil && still.activity == nil)
        let gone = planner.plan(tabID: "T", snap("working"))
        #expect(gone.alert == nil)
        #expect(gone.activity?.asking == false)
        let unnamed = planner.plan(tabID: "T", snap("working", question: ""))
        #expect(unnamed.alert?.body == "Needs your approval.")
    }

    @Test func alertsAreBoundedAndSealedApart() throws {
        let alert = RemoteAlert(
            kind: .finished, tabID: "T", title: String(repeating: "t", count: 200),
            body: String(repeating: "b", count: 400))
        #expect(alert.title.count == 96)
        #expect(alert.body.count == 200)
        let key = RemoteCrypto.randomKey()
        let sealed = try RemoteCrypto.seal(alert, key: key, direction: RemoteAlert.direction)
        let opened: RemoteAlert = try RemoteCrypto.open(sealed, key: key, direction: RemoteAlert.direction)
        #expect(opened == alert)
        #expect((try? RemoteCrypto.open(sealed, key: key, direction: "mac") as RemoteAlert) == nil)
        let json = String(decoding: try JSONEncoder().encode(alert), as: UTF8.self)
        #expect(json.contains("\"kind\":\"finished\""))
    }

    @Test func tabsCanBeForgotten() {
        var planner = RemoteAlertPlanner()
        _ = planner.plan(tabID: "A", snap("working"))
        _ = planner.plan(tabID: "B", snap("working"))
        planner.forget(tabID: "A")
        #expect(planner.knownTabs == ["B"])
        #expect(planner.plan(tabID: "A", snap("idle")).alert == nil)
    }
}
