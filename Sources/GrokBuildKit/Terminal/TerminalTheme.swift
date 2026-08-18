import Foundation
import SwiftTerm

/// A terminal colour scheme.
///
/// IMPLEMENTATION PENDING — this file declares the API the app is written against.
public struct TerminalTheme: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isDark: Bool

    public init(name: String, isDark: Bool) {
        self.name = name
        self.isDark = isDark
    }

    /// The 16 ANSI colours, in standard order.
    public var ansi: [SwiftTerm.Color] { [] }
    /// Background, foreground, cursor and selection colours.
    public var background: SwiftTerm.Color { SwiftTerm.Color(red: 0, green: 0, blue: 0) }
    public var foreground: SwiftTerm.Color { SwiftTerm.Color(red: 0, green: 0, blue: 0) }
    public var cursor: SwiftTerm.Color { SwiftTerm.Color(red: 0, green: 0, blue: 0) }
    public var selection: SwiftTerm.Color { SwiftTerm.Color(red: 0, green: 0, blue: 0) }

    /// Themes the app offers, `grokNight` first.
    public static let all: [TerminalTheme] = []
    public static let grokNight = TerminalTheme(name: "Grok Night", isDark: true)
    public static let grokDay = TerminalTheme(name: "Grok Day", isDark: false)
}
