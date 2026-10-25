import Foundation
import Testing

@testable import SigilKit

struct OpenTabsSnapshotTests {

    @Test func encodeDecodeRoundTrips() throws {
        let snapshot = OpenTabsSnapshot(
            tabs: [
                .init(sessionID: "019f780a-34d7-7993-aadc-f23a46c40a73", cwd: "/Users/exec/proj"),
                .init(sessionID: "019ffeab-c76b-7fe1-be40-508369febd51", cwd: "/tmp/work"),
            ],
            selectedSessionID: "019ffeab-c76b-7fe1-be40-508369febd51",
            selectedCWD: "/tmp/work"
        )
        let data = try #require(snapshot.encode())
        let decoded = try #require(OpenTabsSnapshot.decode(data))
        #expect(decoded == snapshot)
    }

    @Test func encodeDecodeRoundTripsEmptySelection() throws {
        let snapshot = OpenTabsSnapshot(tabs: [], selectedSessionID: nil)
        let data = try #require(snapshot.encode())
        let decoded = try #require(OpenTabsSnapshot.decode(data))
        #expect(decoded == snapshot)
    }

    @Test func decodeRejectsGarbage() {
        #expect(OpenTabsSnapshot.decode(Data("not-json".utf8)) == nil)
    }

    @Test func decodesSnapshotsFromBeforeSelectedFolderWasStored() throws {
        let data = Data(
            #"{"tabs":[{"sessionID":"same","cwd":"/old/project"}],"selectedSessionID":"same"}"#.utf8
        )
        let decoded = try #require(OpenTabsSnapshot.decode(data))
        #expect(decoded.selectedSessionID == "same")
        #expect(decoded.selectedCWD == nil)
        #expect(decoded.tabs.first?.taskID == nil)
    }

    @Test func anExplicitTaskIDRoundTripsWithoutReplacingNativeIdentity() throws {
        let task = UUID().uuidString.lowercased()
        let snapshot = OpenTabsSnapshot(
            tabs: [.init(sessionID: "native", cwd: "/generated/project", provider: .claudeCode, taskID: task)],
            selectedSessionID: "native")
        let encoded = try #require(snapshot.encode())
        let decoded = try #require(OpenTabsSnapshot.decode(encoded))
        #expect(decoded.tabs.first?.taskID == task)
        #expect(decoded.tabs.first?.sessionID == "native")
        #expect(decoded.tabs.first?.provider == .claudeCode)
    }
}
