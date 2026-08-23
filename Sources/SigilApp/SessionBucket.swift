import Foundation
import SigilKit

/// Recency buckets for the sidebar, the way a thread list is normally read:
/// today first, then a few relative windows, then by month.
struct SessionBucket: Identifiable {
    let id: String
    let title: String
    let sessions: [GrokSession]

    /// Splits `sessions` (already newest-first) into buckets, dropping empty ones.
    static func bucket(_ sessions: [GrokSession], now: Date = Date(), calendar: Calendar = .current)
        -> [SessionBucket]
    {
        var order: [String] = []
        var titles: [String: String] = [:]
        var grouped: [String: [GrokSession]] = [:]

        let startOfToday = calendar.startOfDay(for: now)

        for session in sessions {
            let (key, title) = label(
                for: session.updatedAt, startOfToday: startOfToday, calendar: calendar)
            if grouped[key] == nil {
                order.append(key)
                titles[key] = title
                grouped[key] = [session]
            } else {
                grouped[key]?.append(session)
            }
        }

        return order.map {
            SessionBucket(id: $0, title: titles[$0] ?? $0, sessions: grouped[$0] ?? [])
        }
    }

    private static func label(for date: Date, startOfToday: Date, calendar: Calendar) -> (
        key: String, title: String
    ) {
        if date >= startOfToday { return ("0-today", "Today") }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
            return ("9-earlier", "Earlier")
        }
        if date >= yesterday { return ("1-yesterday", "Yesterday") }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday), date >= weekAgo {
            return ("2-week", "Previous 7 days")
        }
        if let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday),
            date >= monthAgo
        {
            return ("3-month", "Previous 30 days")
        }
        let month = date.formatted(.dateTime.year().month(.wide))
        return ("4-\(date.formatted(.iso8601.year().month()))", month)
    }
}

extension Date {
    /// Relative time for the sidebar. Clock skew between the CLI and the app can
    /// make a just-written timestamp look like the future, so anything inside a
    /// minute reads as "now".
    var shortRelative: String {
        let seconds = Date().timeIntervalSince(self)
        if abs(seconds) < 60 { return "now" }
        return formatted(.relative(presentation: .numeric))
    }

}
