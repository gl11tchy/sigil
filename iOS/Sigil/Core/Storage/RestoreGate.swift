import Foundation

/// Decides whether a cached screen, read off the main actor, may still land. Only
/// the newest restore can, and only while its Mac is on screen and nothing live
/// has arrived. It counts changes instead of looking at the tabs: a Mac with no
/// sessions sends an empty tab list, which looks just like nothing yet.
struct RestoreGate {
    struct Ticket: Equatable {
        let macID: String
        fileprivate let generation: Int
    }

    private var generation = 0

    /// Starts a restore for the Mac about to be shown. Every earlier restore is stale.
    mutating func begin(macID: String) -> Ticket {
        generation += 1
        return Ticket(macID: macID, generation: generation)
    }

    /// The screen changed under any restore in flight: live state arrived, or the Mac's state was cleared.
    mutating func invalidate() {
        generation += 1
    }

    func isCurrent(_ ticket: Ticket, activeMacID: String?) -> Bool {
        ticket.generation == generation && ticket.macID == activeMacID
    }
}
