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

        while let line = readLine(strippingNewline: true) {
            guard let response = service.handleLine(line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
            fflush(stdout)
        }
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
