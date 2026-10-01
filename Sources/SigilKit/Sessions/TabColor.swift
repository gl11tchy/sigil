import Foundation

/// A color the user assigned to a conversation, so a tab can be told apart
/// when the titles are truncated. The hues are the Sigil Neon marks.
/// They are identity, not text, and not the working-state dot.
public enum TabColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case mint
    case cyan
    case violet
    case amber
    case magenta

    public var id: String { rawValue }

    /// The word in the menu.
    public var label: String {
        switch self {
        case .mint: "Mint"
        case .cyan: "Cyan"
        case .violet: "Violet"
        case .amber: "Amber"
        case .magenta: "Magenta"
        }
    }

    /// Sigil Neon. Not adjusted for text contrast: the mark is a bar, not a letter.
    public var hex: UInt32 {
        switch self {
        case .mint: 0x4EF0C4
        case .cyan: 0x5AD9FF
        case .violet: 0xA98BFF
        case .amber: 0xFFC46B
        case .magenta: 0xFF5F9E
        }
    }
}

/// One saved tab color. Identity is session id + working directory, the same
/// key a custom conversation name uses.
public struct TabColorRecord: Codable, Equatable, Sendable {
    public var sessionID: String
    public var cwd: String
    public var color: TabColor

    public init(sessionID: String, cwd: String, color: TabColor) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.color = color
    }
}

/// Overlay a remembered color on a conversation. `nil` clears it.
public enum TabColors {
    public static func color(
        sessionID: String,
        cwd: String,
        in records: [TabColorRecord],
        samePath: (String, String) -> Bool
    ) -> TabColor? {
        records.first { $0.sessionID == sessionID && samePath($0.cwd, cwd) }?.color
    }

    /// `nil` removes the mark. Setting the color it already has is a no-op,
    /// so an unchanged list is not written again.
    public static func setting(
        _ color: TabColor?,
        sessionID: String,
        cwd: String,
        onto records: [TabColorRecord],
        samePath: (String, String) -> Bool
    ) -> [TabColorRecord] {
        if self.color(sessionID: sessionID, cwd: cwd, in: records, samePath: samePath) == color {
            return records
        }
        var next = removing(sessionID: sessionID, cwd: cwd, from: records, samePath: samePath)
        if let color {
            next.insert(
                TabColorRecord(sessionID: sessionID, cwd: cwd, color: color),
                at: 0
            )
        }
        return next
    }

    public static func removing(
        sessionID: String,
        cwd: String,
        from records: [TabColorRecord],
        samePath: (String, String) -> Bool
    ) -> [TabColorRecord] {
        records.filter { !($0.sessionID == sessionID && samePath($0.cwd, cwd)) }
    }

    /// One checkbox in the color menu changed.
    /// Turning a mark on selects it. Turning the current mark off clears it.
    /// Turning any other mark off keeps the current color, so a second
    /// checkbox update cannot wipe a selection that just landed.
    public static func choosing(_ mark: TabColor, isOn: Bool, current: TabColor?) -> TabColor? {
        if isOn { return mark }
        return current == mark ? nil : current
    }

    /// Drops a row whose color this build does not know. Garbage is `nil`,
    /// so the caller can keep the previous list instead of wiping it.
    public static func decode(_ data: Data) -> [TabColorRecord]? {
        struct Row: Decodable {
            var sessionID: String
            var cwd: String
            var color: String
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows.compactMap { row in
            guard let color = TabColor(rawValue: row.color) else { return nil }
            return TabColorRecord(sessionID: row.sessionID, cwd: row.cwd, color: color)
        }
    }
}
