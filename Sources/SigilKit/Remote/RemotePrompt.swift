import CryptoKit
import Foundation

/// A pending interaction, or explicitly unverified terminal text that resembles one.
/// Only a provider-backed interaction may authorize a structured response.
public struct RemotePrompt: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        public var label: String
        public var key: String

        public init(label: String, key: String) {
            self.label = label
            self.key = key
        }
    }

    public enum Style: String, Codable, Sendable {
        case menu
        case yesNo
    }

    /// Opaque host interaction identity on the wire. A detector's digest alone
    /// is NOT an interaction identity; RemoteInteraction replaces it before display.
    public var id: String
    public var question: String
    public var style: Style
    public var choices: [Choice]
    /// Shortcuts exist only for exact, unambiguous responses. "Always" is not Yes.
    public var yes: String?
    public var no: String?
    /// Operation context, not merely the generic question below the command.
    public var operation: String?
    /// Missing on old clients/hosts means unverified, never verified.
    public var verified: Bool?
    public var sessionID: String?

    public init(
        question: String, style: Style, choices: [Choice], yes: String? = nil, no: String? = nil,
        operation: String? = nil
    ) {
        self.question = question
        self.style = style
        self.choices = choices
        self.yes = yes
        self.no = no
        self.operation = operation
        self.verified = false
        self.id = Self.digest(question: question, style: style, choices: choices, operation: operation)
    }

    /// Length-prefix each field: separators may themselves occur in terminal output.
    static func digest(question: String, style: Style, choices: [Choice], operation: String?) -> String {
        let fields = [style.rawValue, operation ?? "", question] + choices.flatMap { [$0.key, $0.label] }
        let words = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(words.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var contentID: String {
        Self.digest(question: question, style: style, choices: choices, operation: operation)
    }

    /// Only explicit choices. Enter depends on a mutable selection; Escape has
    /// provider-specific meaning, so both stay ordinary terminal controls.
    public var keys: Set<String> {
        Set(choices.map(\.key))
    }
}

/// Reads the last screen rows for an approval question.
public enum PromptDetector {
    /// Rows the question and its options may span, counted from the bottom.
    public static let window = 20

    public static func detect(rows: [String]) -> RemotePrompt? {
        // The screen keeps blank rows under the cursor; the question sits above them.
        var filled = rows
        while let last = filled.last, last.trimmingCharacters(in: .whitespaces).isEmpty { filled.removeLast() }
        // Bound the wire object by declining an oversized hint, not by silently
        // truncating a command or label before comparing it.
        guard filled.reduce(0, { $0 + $1.utf8.count + 1 }) <= 12_000 else { return nil }
        return menu(in: filled) ?? yesNo(in: filled)
    }

    // MARK: Numbered menus

    private struct Option {
        let row: Int
        let number: Int
        let label: String
    }

    /// `❯ 1. Yes` rows numbered 1…n at the bottom of the screen, under a question.
    /// The rows have to sit together: output between them means the menu is gone.
    private static func menu(in rows: [String]) -> RemotePrompt? {
        var options: [Option] = []
        for index in max(0, rows.count - window)..<rows.count {
            let row = rows[index]
            guard let option = option(row, at: index) else {
                // Output between the rows means the menu is gone; a hint under it is part of it.
                if !options.isEmpty, !row.trimmingCharacters(in: .whitespaces).isEmpty, !isHint(row) { options = [] }
                continue
            }
            if option.number == 1 {
                options = [option]
            } else if option.number == options.count + 1 {
                options.append(option)
            } else {
                options = []
            }
        }
        guard options.count >= 2, options.count <= 9, let first = options.first, let last = options.last else {
            return nil
        }
        // Only hints may follow the last row: the menu is what the CLI is waiting on.
        let after = rows[(last.row + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard after.count <= 2, after.allSatisfy(isHint) else { return nil }
        let labels = options.map(\.label)
        let question = questionAbove(row: first.row, in: rows)
        guard question != nil || labels.contains(where: isAnswerWord) else { return nil }
        let yes = options.first { exactAffirmative($0.label) }.map { String($0.number) }
        let no = options.first { exactNegative($0.label) }.map { String($0.number) }
        let context = rows[..<first.row].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return RemotePrompt(
            question: question ?? "", style: .menu,
            choices: options.map { .init(label: $0.label, key: String($0.number)) }, yes: yes, no: no,
            operation: context.isEmpty ? nil : context)
    }

    private static func option(_ row: String, at index: Int) -> Option? {
        var text = Substring(row.trimmingCharacters(in: .whitespaces))
        while let first = text.first, "❯›>•▸".contains(first) || first == " " { text = text.dropFirst() }
        guard let digit = text.first, digit.isNumber, let number = Int(String(digit)) else { return nil }
        var rest = text.dropFirst()
        guard let mark = rest.first, ".)".contains(mark) else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Option(row: index, number: number, label: label)
    }

    /// The closest question above the menu, at most six rows up; a section title
    /// with no question mark does not count.
    private static func questionAbove(row: Int, in rows: [String]) -> String? {
        var index = row - 1
        var seen = 0
        while index >= 0, seen < 6 {
            let text = rows[index].trimmingCharacters(in: .whitespaces)
            index -= 1
            guard !text.isEmpty else { continue }
            seen += 1
            if text.hasSuffix("?") { return text }
        }
        return nil
    }

    // MARK: Yes/no questions

    /// `Allow? [y/N]`, `Continue (y/n)`: the last words on screen.
    private static func yesNo(in rows: [String]) -> RemotePrompt? {
        guard let row = rows.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let text = row.trimmingCharacters(in: .whitespaces)
        guard hasYesNoMarker(text) else { return nil }
        let spelledOut = text.lowercased().replacingOccurrences(of: " ", with: "").contains("yes/no")
        let yes = spelledOut ? "yes" : "y"
        let no = spelledOut ? "no" : "n"
        return RemotePrompt(
            question: text, style: .yesNo,
            choices: [.init(label: "Yes", key: yes), .init(label: "No", key: no)], yes: yes, no: no,
            operation: rows.dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func hasYesNoMarker(_ text: String) -> Bool {
        var folded = text.lowercased().replacingOccurrences(of: " ", with: "")
        // `Overwrite? (yes/no):` waits for input just as `[y/N]` does.
        while let last = folded.last, ":>".contains(last) { folded.removeLast() }
        for marker in ["[y/n]", "(y/n)", "[yes/no]", "(yes/no)"] where folded.hasSuffix(marker) {
            return true
        }
        return false
    }

    // MARK: Words

    private static func isAnswerWord(_ label: String) -> Bool {
        isAffirmative(label) || isNegative(label)
    }

    private static func isAffirmative(_ label: String) -> Bool {
        let word = firstWord(label)
        return ["yes", "allow", "approve", "proceed", "accept", "continue", "always"].contains(word)
    }

    private static func isNegative(_ label: String) -> Bool {
        let word = firstWord(label)
        return ["no", "deny", "reject", "cancel", "decline", "never"].contains(word)
    }

    private static func firstWord(_ label: String) -> String {
        label.lowercased().prefix { $0.isLetter }.description
    }

    /// Rows a CLI shows under a menu without waiting on them.
    private static func isHint(_ row: String) -> Bool {
        let text = row.lowercased()
        return text.contains("esc") || text.contains("enter") || text.contains("↑") || text.contains("↓")
            || text.contains("arrow") || text.contains("select")
    }

    private static func exactAffirmative(_ label: String) -> Bool {
        ["yes", "yes (y)", "allow once", "approve once"].contains(label.lowercased())
    }

    private static func exactNegative(_ label: String) -> Bool {
        ["no", "no (n)", "deny", "reject", "cancel"].contains(label.lowercased())
    }
}
