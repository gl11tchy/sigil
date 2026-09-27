import Foundation
import SigilKit
import Testing

@testable import SigilApp

/// Pins, archives and names found by chat id first answer exactly what the
/// per-entry `samePath` scans answered.
struct MacSidebarIdentityIndexTests {
    /// Folders with two spellings each, as `/var/…` and `/private/var/…` or a
    /// symlink and its target resolve to one canonical path.
    private static let folders = ["/work/alpha", "/work/beta", "/work/gamma", "/work/delta"]
    private static func canonical(_ path: String) -> String {
        path.hasPrefix("/link/") ? "/work/" + path.dropFirst("/link/".count) : path
    }
    private static func spelling(of folder: String, using rng: inout SplitMix64) -> String {
        Bool.random(using: &rng) ? folder : "/link/" + folder.dropFirst("/work/".count)
    }
    private static func samePath(_ lhs: String, _ rhs: String) -> Bool { canonical(lhs) == canonical(rhs) }

    @Test func idFirstPinArchiveAndNameLookupsMatchTheScans() {
        let samePath: (String, String) -> Bool = Self.samePath
        for seed in UInt64(1)...60 {
            var rng = SplitMix64(seed: seed)
            let fixture = Fixture(using: &rng)

            #expect(
                SidebarOrganization.matching(sessions: fixture.sessions, entries: fixture.pins, samePath: samePath)
                    == MacSidebarReferenceScan.matching(
                        sessions: fixture.sessions, entries: fixture.pins, samePath: samePath),
                "seed \(seed)")
            let projects: [SidebarProject?] =
                [nil] + SidebarOrganization.projects(from: fixture.sessions, canonicalPath: Self.canonical).map { $0 }
            for project in projects {
                #expect(
                    SidebarOrganization.pinned(
                        sessions: fixture.sessions, entries: fixture.pins, in: project, samePath: samePath)
                        == MacSidebarReferenceScan.pinned(
                            sessions: fixture.sessions, entries: fixture.pins, in: project, samePath: samePath),
                    "seed \(seed) \(project?.cwd ?? "all")")
            }
            #expect(
                SidebarOrganization.without(sessions: fixture.sessions, entries: fixture.pins, samePath: samePath)
                    == MacSidebarReferenceScan.without(
                        sessions: fixture.sessions, entries: fixture.pins, samePath: samePath),
                "seed \(seed)")

            let archived = ConversationIndex(fixture.archives, sessionID: \.sessionID, cwd: \.cwd)
            let names = ConversationIndex(fixture.names, sessionID: \.sessionID, cwd: \.cwd)
            for session in fixture.sessions {
                #expect(
                    archived.contains(sessionID: session.id, cwd: session.cwd, samePath: samePath)
                        == SidebarOrganization.contains(fixture.archives, session: session, samePath: samePath),
                    "seed \(seed) \(session.id) \(session.cwd)")
                #expect(
                    names.first(sessionID: session.id, cwd: session.cwd, samePath: samePath)
                        .flatMap { ConversationNaming.normalized($0.name) }
                        == ConversationNaming.name(for: session, in: fixture.names, samePath: samePath),
                    "seed \(seed) \(session.id) \(session.cwd)")
            }
        }
    }

    /// A chat id in two folders is two chats; one id under two spellings of a
    /// folder is one. Pin order and the first matching row both survive.
    @Test func idFirstKeepsDuplicateIdsApartAndPinOrder() {
        let inAlpha = session(id: "same", cwd: "/work/alpha", updated: 3)
        let inBeta = session(id: "same", cwd: "/work/beta", updated: 2)
        let alphaAlias = session(id: "same", cwd: "/link/alpha", updated: 1)
        let other = session(id: "other", cwd: "/work/alpha", updated: 0)
        let sessions = [inAlpha, inBeta, alphaAlias, other]
        let pins = [
            OpenTabsSnapshot.Entry(sessionID: "other", cwd: "/link/alpha"),
            OpenTabsSnapshot.Entry(sessionID: "same", cwd: "/link/alpha"),
            OpenTabsSnapshot.Entry(sessionID: "same", cwd: "/work/alpha"),
            OpenTabsSnapshot.Entry(sessionID: "gone", cwd: "/work/alpha"),
        ]
        let pinned = SidebarOrganization.pinned(sessions: sessions, entries: pins, in: nil, samePath: Self.samePath)
        #expect(pinned.map(\.cwd) == ["/work/alpha", "/work/alpha", "/work/alpha"])
        #expect(pinned.map(\.id) == ["other", "same", "same"])
        #expect(SidebarOrganization.without(sessions: sessions, entries: pins, samePath: Self.samePath) == [inBeta])

        let names = ConversationIndex(
            [
                ConversationName(sessionID: "same", cwd: "/link/alpha", name: "  "),
                ConversationName(sessionID: "same", cwd: "/work/alpha", name: "Later record"),
                ConversationName(sessionID: "same", cwd: "/work/beta", name: " Beta name "),
            ],
            sessionID: \.sessionID, cwd: \.cwd)
        // The first record wins even when it is blank, as the scan's `first` does.
        #expect(names.first(sessionID: "same", cwd: inAlpha.cwd, samePath: Self.samePath)?.name == "  ")
        #expect(names.first(sessionID: "same", cwd: inBeta.cwd, samePath: Self.samePath)?.name == " Beta name ")
    }

    /// Folders, the costly part (canonical paths), are compared only between a
    /// chat and the saved records with its id: never once per chat, never per
    /// chat and record pair.
    @Test func foldersAreComparedOnlyForTheSameId() {
        let sessionCount = 2_000
        let pinCount = 500
        let sessions = (0..<sessionCount).map {
            session(id: "s\($0)", cwd: Self.folders[$0 % Self.folders.count], updated: Double(sessionCount - $0))
        }
        let pins = sessions.suffix(pinCount).map { SidebarOrganization.entry(for: $0) }
        var compared = 0
        let samePath: (String, String) -> Bool = {
            compared += 1
            return Self.samePath($0, $1)
        }
        let pinned = SidebarOrganization.pinned(sessions: sessions, entries: pins, in: nil, samePath: samePath)
        #expect(pinned.count == pinCount)
        #expect(compared == pinCount)

        compared = 0
        let unpinned = SidebarOrganization.without(sessions: sessions, entries: pins, samePath: samePath)
        #expect(unpinned.count == sessionCount - pinCount)
        #expect(compared == pinCount)

        compared = 0
        let archived = ConversationIndex(pins, sessionID: \.sessionID, cwd: \.cwd)
        #expect(
            sessions.filter { archived.contains(sessionID: $0.id, cwd: $0.cwd, samePath: samePath) }.count == pinCount)
        #expect(compared == pinCount)
    }

    private struct Fixture {
        var sessions: [GrokSession] = []
        var pins: [OpenTabsSnapshot.Entry] = []
        var archives: [OpenTabsSnapshot.Entry] = []
        var names: [ConversationName] = []

        init(using rng: inout SplitMix64) {
            let ids = (0..<Int.random(in: 4...14, using: &rng)).map { "id\($0)" }
            for index in 0..<Int.random(in: 0...40, using: &rng) {
                // Few ids across many rows: the same id in several folders and
                // under both spellings of one folder.
                let id = ids.randomElement(using: &rng)!
                let folder = MacSidebarIdentityIndexTests.folders.randomElement(using: &rng)!
                sessions.append(
                    session(
                        id: id, cwd: MacSidebarIdentityIndexTests.spelling(of: folder, using: &rng),
                        updated: Double(Int.random(in: 0...5, using: &rng)) + Double(index) / 1_000))
            }
            func entry(using rng: inout SplitMix64) -> OpenTabsSnapshot.Entry {
                let folder = MacSidebarIdentityIndexTests.folders.randomElement(using: &rng)!
                return OpenTabsSnapshot.Entry(
                    sessionID: Bool.random(using: &rng) ? ids.randomElement(using: &rng)! : "missing",
                    cwd: MacSidebarIdentityIndexTests.spelling(of: folder, using: &rng))
            }
            pins = (0..<Int.random(in: 0...20, using: &rng)).map { _ in entry(using: &rng) }
            archives = (0..<Int.random(in: 0...20, using: &rng)).map { _ in entry(using: &rng) }
            names = (0..<Int.random(in: 0...20, using: &rng)).map { index in
                let target = entry(using: &rng)
                let name = ["", "  ", "Renamed \(index)", " Padded \(index) "].randomElement(using: &rng)!
                return ConversationName(sessionID: target.sessionID, cwd: target.cwd, name: name)
            }
        }
    }
}

/// The per-entry scans the id-first lookups replaced, as they were: the
/// reference the equivalence tests compare against.
enum MacSidebarReferenceScan {
    static func matching(
        sessions: [GrokSession],
        entries: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [GrokSession] {
        entries.compactMap { entry in
            sessions.first { $0.id == entry.sessionID && samePath($0.cwd, entry.cwd) }
        }
    }

    static func pinned(
        sessions: [GrokSession],
        entries: [OpenTabsSnapshot.Entry],
        in project: SidebarProject?,
        samePath: (String, String) -> Bool
    ) -> [GrokSession] {
        let pinned = matching(sessions: sessions, entries: entries, samePath: samePath)
        guard let project else { return pinned }
        return pinned.filter { session in
            project.sessions.contains {
                $0.id == session.id && samePath($0.cwd, session.cwd)
            }
        }
    }

    static func without(
        sessions: [GrokSession],
        entries: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [GrokSession] {
        sessions.filter { session in
            !SidebarOrganization.contains(entries, session: session, samePath: samePath)
        }
    }
}

/// Deterministic generator so a failing seed reproduces.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func session(id: String, cwd: String, updated: TimeInterval) -> GrokSession {
    GrokSession(
        id: id,
        cwd: cwd,
        summary: "Session \(id)",
        createdAt: Date(timeIntervalSince1970: updated),
        updatedAt: Date(timeIntervalSince1970: updated),
        messageCount: 4,
        modelID: nil,
        agentName: nil,
        reasoningEffort: nil,
        directory: URL(fileURLWithPath: cwd).appendingPathComponent(id)
    )
}
