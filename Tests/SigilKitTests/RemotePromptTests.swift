import Foundation
import Testing

@testable import SigilKit

struct RemotePromptTests {
    private func rows(_ screen: String) -> [String] {
        screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func claudeCodeMenuIsAPromptWithYesAndNoKeys() throws {
        let screen = """
            Bash command

              git status
              Show working tree status

            Do you want to proceed?
            ❯ 1. Yes
              2. Yes, and don't ask again for git status commands in /Users/x
              3. No, and tell Claude what to do differently (esc)

            """
        let prompt = try #require(PromptDetector.detect(rows: rows(screen)))
        #expect(prompt.style == .menu)
        #expect(prompt.question == "Do you want to proceed?")
        #expect(prompt.choices.map(\.key) == ["1", "2", "3"])
        #expect(prompt.choices[2].label.hasPrefix("No, and tell Claude"))
        #expect(prompt.yes == "1")
        #expect(prompt.no == "3")
        #expect(prompt.keys.isSuperset(of: ["1", "2", "3", "enter", "escape"]))
    }

    @Test func codexMenuWithHintsBelowStillCounts() throws {
        let screen = """
            Codex wants to run: rm -rf build

              1. Yes (y)
              2. Yes, and don't ask again this session (a)
              3. No, and tell Codex what to do differently (esc)

              Press Enter to confirm or Esc to cancel
            """
        let prompt = try #require(PromptDetector.detect(rows: rows(screen)))
        #expect(prompt.question == "")
        #expect(prompt.choices.count == 3)
        #expect(prompt.yes == "1" && prompt.no == "3")
    }

    @Test func menuWithoutYesRowsPicksEscapeForNo() throws {
        let screen = """
            Which file should I edit?
            › 1. README.md
              2. CHANGELOG.md
            """
        let prompt = try #require(PromptDetector.detect(rows: rows(screen)))
        #expect(prompt.yes == "1")
        #expect(prompt.no == "escape")
    }

    @Test func yesNoQuestionsUseLetters() throws {
        for line in ["Allow tool execution? [y/N]", "Continue (y/n):", "Overwrite the file? (yes/no)"] {
            let prompt = try #require(PromptDetector.detect(rows: ["output", line]), "\(line)")
            #expect(prompt.style == .yesNo)
            #expect(prompt.yes == "y" && prompt.no == "n")
            #expect(prompt.question == line)
        }
    }

    @Test func plainOutputIsNotAPrompt() {
        let table = [
            // A numbered list in prose, with no question and no answer words.
            "Plan:\n1. Install the dependencies\n2. Run the tests\n3. Ship it\n",
            // A menu that scrolled away under more output.
            "Do you want to proceed?\n1. Yes\n2. No\nRunning git status...\nOn branch main\nnothing to commit\n",
            // One numbered row is a list item, not a menu.
            "Do you want to proceed?\n1. Yes\n",
            // Numbers out of order are not a menu.
            "Choose?\n2. Yes\n1. No\n",
            // A y/n marker in the middle of a paragraph is prose.
            "Type [y/n] at the prompt to answer\nand then press Return\n",
            "",
        ]
        for screen in table {
            #expect(PromptDetector.detect(rows: rows(screen)) == nil, Comment(rawValue: screen))
        }
    }

    @Test func outputBetweenRowsEndsTheMenu() {
        #expect(PromptDetector.detect(rows: ["Proceed?", "1. Yes", "finished task", "2. No"]) == nil)
        #expect(PromptDetector.detect(rows: ["Proceed?", "1. Yes", "", "2. No"])?.choices.count == 2)
        // A new menu after an old one counts on its own.
        let again = PromptDetector.detect(rows: [
            "Proceed?", "1. Yes", "2. No", "done", "Again?", "1. Yes", "2. No", "3. Later",
        ])
        #expect(again?.choices.count == 3)
        #expect(again?.question == "Again?")
    }

    @Test func colonAndPromptTerminatedYesNoCount() throws {
        for line in ["Overwrite the file? (yes/no):", "Continue? [Y/n]:", "Allow [y/n] >"] {
            #expect(PromptDetector.detect(rows: [line])?.style == .yesNo, "\(line)")
        }
    }

    @Test func theIdFollowsTheWordsOnScreen() {
        let first = PromptDetector.detect(rows: ["Proceed?", "1. Yes", "2. No"])
        let same = PromptDetector.detect(rows: ["Proceed?", "1. Yes", "2. No"])
        let other = PromptDetector.detect(rows: ["Delete it?", "1. Yes", "2. No"])
        let widerMenu = PromptDetector.detect(rows: ["Proceed?", "1. Yes", "2. No", "3. Ask"])
        #expect(first?.id == same?.id)
        #expect(first?.id != other?.id)
        #expect(first?.id != widerMenu?.id)
        #expect(first?.id.count == 24)
    }

    @Test func onlyTheLastFilledRowsAreRead() throws {
        var lines = ["Do you want to proceed?", "1. Yes", "2. No"]
        // Blank rows under the cursor do not hide the question.
        let blank = lines + Array(repeating: "   ", count: PromptDetector.window)
        #expect(try #require(PromptDetector.detect(rows: blank)).choices.count == 2)
        lines += Array(repeating: "more output", count: PromptDetector.window)
        #expect(PromptDetector.detect(rows: lines) == nil)
    }

    @Test func labelsAndQuestionsAreBounded() throws {
        let long = String(repeating: "x", count: 500)
        let screen = "Proceed?\n1. Yes \(long)\n2. No"
        let prompt = try #require(PromptDetector.detect(rows: rows(screen)))
        #expect(prompt.choices[0].label.count <= 300)
        #expect(PromptDetector.detect(rows: ["\(long)?", "1. Yes", "2. No"])?.question.count == 300)
    }

    @Test func promptRoundTripsThroughJSON() throws {
        let prompt = RemotePrompt(
            question: "Proceed?", style: .menu, choices: [.init(label: "Yes", key: "1")], yes: "1", no: "escape")
        let data = try JSONEncoder().encode(prompt)
        #expect(try JSONDecoder().decode(RemotePrompt.self, from: data) == prompt)
        #expect(String(decoding: data, as: UTF8.self).contains("\"style\":\"menu\""))
    }
}
