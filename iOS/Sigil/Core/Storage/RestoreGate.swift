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
    /// The restore the screen waits for instead of showing an empty Mac, until it
    /// lands, finds nothing, runs out of time or goes stale.
    private(set) var awaited: Ticket?

    /// The longest the screen waits for a cache on disk before it shows what it has.
    static let patience = Duration.seconds(1)

    var isAwaiting: Bool { awaited != nil }

    /// Starts a restore for the Mac about to be shown. Every earlier restore is stale.
    /// `awaited` when a cache is on disk and the screen should wait for it.
    mutating func begin(macID: String, awaited: Bool = false) -> Ticket {
        generation += 1
        let ticket = Ticket(macID: macID, generation: generation)
        self.awaited = awaited ? ticket : nil
        return ticket
    }

    /// The screen changed under any restore in flight: live state arrived, or the Mac's state was cleared.
    mutating func invalidate() {
        generation += 1
        awaited = nil
    }

    /// The restore landed, found nothing or ran out of time: the screen waits no more.
    mutating func finish(_ ticket: Ticket) {
        if awaited == ticket { awaited = nil }
    }

    func isCurrent(_ ticket: Ticket, activeMacID: String?) -> Bool {
        ticket.generation == generation && ticket.macID == activeMacID
    }
}
