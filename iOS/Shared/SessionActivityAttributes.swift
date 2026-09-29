import Foundation

#if os(iOS)
    import ActivityKit

    /// A working session on the Lock Screen. The static part is set when the
    /// activity starts; the state changes locally while the app is open and by
    /// push from the Mac through the relay after that, with exactly these keys.
    struct SessionActivityAttributes: ActivityAttributes {
        struct ContentState: Codable, Hashable {
            /// `starting`, `working`, `idle` or `exited`, as the Mac reports.
            var status: String
            /// Seconds since 1970 when this status began.
            var since: Int
            /// The session shows an approval question.
            var asking: Bool
        }

        var tabID: String
        var title: String
        var provider: String
        var mac: String
        /// The pairing this session belongs to, so the card opens the right Mac.
        var macID: String?
    }
#endif
