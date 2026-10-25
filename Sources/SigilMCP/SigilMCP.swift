import Darwin
import Foundation
import SigilKit

@main
struct SigilMCP {
    static func main() {
        let client = BridgeClient()
        let service = MCPStdioService { request in
            try client.send(request, timeout: socketTimeout(for: request))
        }
        let writer = LockedOutput()
        let session = MCPStdioSession(service: service) { response in
            writer.write(response)
        }

        while let line = readLine(strippingNewline: true) {
            session.receive(line)
        }
        session.cancelAll()
    }

    /// `ask_tab` holds the socket until the other tab answers, so the receive
    /// timeout has to outlast that wait. Other methods return immediately.
    private static func socketTimeout(for request: BridgeRequest) -> Double {
        switch request.method {
        case .askTab:
            return BridgeLimits.clampedAskSeconds(request.timeoutSeconds) + 30
        case .listTabs, .sendToTab, .replyTo:
            return 15
        }
    }
}

private final class LockedOutput: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ line: String) {
        lock.lock()
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        fflush(stdout)
        lock.unlock()
    }
}
