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
        // Key and title both come from the caller's calendar, so a local evening on
        // the last day of a month never lands in the next month's bucket.
        let parts = calendar.dateComponents([.year, .month], from: date)
        let key = String(format: "4-%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        return (key, date.formatted(style.year().month(.wide)))
    }
}

extension Date {
    /// Relative time for the sidebar. Clock skew between the CLI and the app can
    /// make a just-written timestamp look like the future, so anything inside a
    /// minute reads as "now".
    ///
    /// Compact on purpose: the subtitle is metadata in mono, and a column of
    /// "14 minutes ago" is noise where "14m" scans. `longRelative` spells it out
    /// where there is room (tooltips, accessibility). `now` is the sidebar's
    /// minute tick, so the label moves with the clock.
    func shortRelative(to now: Date) -> String {
        let seconds = now.timeIntervalSince(self)
        if abs(seconds) < 60 { return "now" }
        let minutes = Int(abs(seconds) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        if days < 35 { return "\(days / 7)w" }
        return formatted(.dateTime.month(.abbreviated).day())
    }

    /// Spelled-out relative time for tooltips and accessibility labels.
    func longRelative(to now: Date) -> String {
        let seconds = now.timeIntervalSince(self)
        if abs(seconds) < 60 { return "now" }
        // The relative style always measures from the system clock; shift the
        // date so it reads the same interval as from `now`.
        return Date.now.addingTimeInterval(-seconds).formatted(.relative(presentation: .numeric))
    }
}
