import CryptoKit
import Foundation

/// An approval question a CLI is showing at the bottom of its screen, as the
/// phone's answer buttons need it. Detection is a hint for buttons and alerts;
/// nothing is sent until the phone asks.
public struct RemotePrompt: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        public var label: String
        /// What `answer` sends: a digit for a menu row, `y` or `n` for a yes/no question.
        public var key: String

        public init(label: String, key: String) {
            self.label = label
            self.key = key
        }
    }

    public enum Style: String, Codable, Sendable {
        /// Numbered rows: the digit picks the row.
        case menu
        /// `[y/n]`: the letter, then Return.
        case yesNo
    }

    /// A digest of the words on screen. An answer names it, so a tap meant for
    /// one question cannot land on the question that replaced it.
    public var id: String
    public var question: String
    public var style: Style
    public var choices: [Choice]
    /// The keys the Yes and No buttons send. `escape` when a menu has no "No" row.
    public var yes: String
    public var no: String

    public init(question: String, style: Style, choices: [Choice], yes: String, no: String) {
        self.question = question
        self.style = style
        self.choices = choices
        self.yes = yes
        self.no = no
        self.id = Self.digest(question: question, style: style, choices: choices)
    }

    static func digest(question: String, style: Style, choices: [Choice]) -> String {
        let words = ([style.rawValue, question] + choices.flatMap { [$0.key, $0.label] }).joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(words.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Every key `answer` may send for this prompt.
    public var keys: Set<String> {
        Set(choices.map(\.key) + [yes, no, "enter", "escape"])
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
        let tail = Array(filled.suffix(window))
        return menu(in: tail) ?? yesNo(in: tail)
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
        for (index, row) in rows.enumerated() {
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
        let yes = options.first { isAffirmative($0.label) }.map { String($0.number) } ?? "1"
        let no = options.first { isNegative($0.label) }.map { String($0.number) } ?? "escape"
        return RemotePrompt(
            question: bounded(question ?? ""), style: .menu,
            choices: options.map { .init(label: bounded($0.label), key: String($0.number)) }, yes: yes, no: no)
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
        return RemotePrompt(question: bounded(text), style: .yesNo, choices: [], yes: "y", no: "n")
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

    private static func bounded(_ text: String) -> String {
        String(text.prefix(300))
    }
}
