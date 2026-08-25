import Foundation
import SigilKit
import Testing

@testable import SigilApp

struct SidebarOrganizationTests {
    @Test func pinningPrependsAndIsIdempotentOnIdentity() {
        let first = session(id: "a", cwd: "/tmp/one", updated: 2)
        let second = session(id: "b", cwd: "/tmp/two", updated: 1)
        var pins: [OpenTabsSnapshot.Entry] = []
        pins = SidebarOrganization.inserting(first, onto: pins, samePath: ==)
        pins = SidebarOrganization.inserting(second, onto: pins, samePath: ==)
        #expect(pins.map(\.sessionID) == ["b", "a"])

        pins = SidebarOrganization.inserting(first, onto: pins, samePath: ==)
        #expect(pins.map(\.sessionID) == ["a", "b"])
    }

    @Test func pinsMatchByIdAndWorkingDirectory() {
        let kept = session(id: "same", cwd: "/tmp/one", updated: 2)
        let otherFolder = session(id: "same", cwd: "/tmp/two", updated: 1)
        let pins = [
            OpenTabsSnapshot.Entry(sessionID: "same", cwd: "/tmp/one")
        ]
        let matched = SidebarOrganization.matching(
            sessions: [otherFolder, kept],
            entries: pins,
            samePath: ==
        )
        #expect(matched.map(\.cwd) == ["/tmp/one"])
        #expect(
            SidebarOrganization.without(
                sessions: [otherFolder, kept],
                entries: pins,
                samePath: ==
            ).map(\.cwd) == ["/tmp/two"]
        )
    }

    @Test func projectPinningPrependsAndIsIdempotentOnPath() {
        var pins: [String] = []
        pins = SidebarOrganization.inserting("/tmp/one", onto: pins, samePath: ==)
        pins = SidebarOrganization.inserting("/tmp/two", onto: pins, samePath: ==)
        #expect(pins == ["/tmp/two", "/tmp/one"])

        pins = SidebarOrganization.inserting("/tmp/one", onto: pins, samePath: ==)
        #expect(pins == ["/tmp/one", "/tmp/two"])
    }

    @Test func projectPinsMatchByCanonicalWorkingDirectory() {
        let newer = session(id: "n", cwd: "/tmp/alias", name: "newer", updated: 3)
        let other = session(id: "p", cwd: "/tmp/other", name: "other", updated: 2)
        let grouped = SidebarOrganization.projects(from: [newer, other]) { path in
            path == "/tmp/alias" ? "/private/tmp/alias" : path
        }
        let samePath: (String, String) -> Bool = { lhs, rhs in
            let canon: (String) -> String = {
                $0 == "/tmp/alias" || $0 == "/private/tmp/alias" ? "/private/tmp/alias" : $0
            }
            return canon(lhs) == canon(rhs)
        }
        let matched = SidebarOrganization.matching(
            projects: grouped,
            paths: ["/private/tmp/alias"],
            samePath: samePath
        )
        #expect(matched.map(\.cwd) == ["/tmp/alias"])
        #expect(
            SidebarOrganization.without(
                projects: grouped,
                paths: ["/tmp/alias"],
                samePath: samePath
            ).map(\.cwd) == ["/tmp/other"]
        )
    }

    @Test func projectsGroupByCanonicalPathAndKeepNewestFirst() {
        let newer = session(id: "n", cwd: "/tmp/alias", name: "newer", updated: 3)
        let older = session(id: "o", cwd: "/tmp/alias", name: "older", updated: 1)
        let other = session(id: "p", cwd: "/tmp/other", name: "other", updated: 2)
        let grouped = SidebarOrganization.projects(from: [newer, other, older]) { path in
            path == "/tmp/alias" ? "/private/tmp/alias" : path
        }
        #expect(grouped.map(\.id) == ["/private/tmp/alias", "/tmp/other"])
        #expect(grouped[0].sessions.map(\.id) == ["n", "o"])
        #expect(grouped[0].count == 2)
        #expect(grouped[1].sessions.map(\.id) == ["p"])
    }
}

private func session(
    id: String,
    cwd: String,
    name: String = "Session",
    updated: TimeInterval
) -> GrokSession {
    GrokSession(
        id: id,
        cwd: cwd,
        summary: name,
        createdAt: Date(timeIntervalSince1970: updated),
        updatedAt: Date(timeIntervalSince1970: updated),
        messageCount: 4,
        modelID: nil,
        agentName: nil,
        reasoningEffort: nil,
        directory: URL(fileURLWithPath: cwd).appendingPathComponent(id)
    )
}
