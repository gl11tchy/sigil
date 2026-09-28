import Foundation
import Testing

@testable import SigilKit

struct RemotePromptTests {
    private func rows(_ screen: String) -> [String] {
        screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func operationContextChangesApprovalIdentity() throws {
        let first = try #require(PromptDetector.detect(rows: ["git status", "Proceed?", "1. Yes", "2. No"]))
        let other = try #require(PromptDetector.detect(rows: ["rm -rf build", "Proceed?", "1. Yes", "2. No"]))
        #expect(first.id != other.id)
    }

    @Test func differencesPastTheOldDisplayLimitChangeIdentity() throws {
        let prefix = String(repeating: "x", count: 350)
        let first = try #require(PromptDetector.detect(rows: ["Proceed?", "1. Yes " + prefix + "safe", "2. No"]))
        let other = try #require(PromptDetector.detect(rows: ["Proceed?", "1. Yes " + prefix + "always", "2. No"]))
        #expect(first.id != other.id)
    }

    @Test func selectionMenusNeverManufactureAnAffirmativeChoice() throws {
        let prompt = try #require(PromptDetector.detect(rows: ["Which file?", "1. README.md", "2. CHANGELOG.md"]))
        #expect(prompt.yes != "1")
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
        #expect(prompt.no == nil)
        #expect(prompt.keys == ["1", "2", "3"])
        #expect(prompt.operation?.contains("git status") == true)
        #expect(prompt.verified == false)
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
        #expect(prompt.yes == "1" && prompt.no == nil)
    }

    @Test func menuWithoutYesRowsHasNoShortcuts() throws {
        let screen = """
            Which file should I edit?
            › 1. README.md
              2. CHANGELOG.md
            """
        let prompt = try #require(PromptDetector.detect(rows: rows(screen)))
        #expect(prompt.yes == nil)
        #expect(prompt.no == nil)
    }

    @Test func yesNoQuestionsUseTheDisplayedAnswerForm() throws {
        for line in ["Allow tool execution? [y/N]", "Continue (y/n):", "Overwrite the file? (yes/no)"] {
            let prompt = try #require(PromptDetector.detect(rows: ["output", line]), "\(line)")
            #expect(prompt.style == .yesNo)
            let spelledOut = line.contains("yes/no")
            #expect(prompt.yes == (spelledOut ? "yes" : "y"))
            #expect(prompt.no == (spelledOut ? "no" : "n"))
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
        #expect(first?.id.count == 64)
    }

    @Test func onlyTheLastFilledRowsAreRead() throws {
        var lines = ["Do you want to proceed?", "1. Yes", "2. No"]
        // Blank rows under the cursor do not hide the question.
        let blank = lines + Array(repeating: "   ", count: PromptDetector.window)
        #expect(try #require(PromptDetector.detect(rows: blank)).choices.count == 2)
        lines += Array(repeating: "more output", count: PromptDetector.window)
        #expect(PromptDetector.detect(rows: lines) == nil)
    }

    @Test func labelsAndQuestionsAreNotSilentlyTruncated() throws {
        let long = String(repeating: "x", count: 500)
        let screen = "Proceed?\n1. Yes \(long)\n2. No"
        let prompt = try #require(PromptDetector.detect(rows: rows(screen)))
        #expect(prompt.choices[0].label == "Yes " + long)
        #expect(PromptDetector.detect(rows: ["\(long)?", "1. Yes", "2. No"])?.question == long + "?")
    }

    @Test func broadPermissionsNeverBecomeYesShortcuts() throws {
        let prompt = try #require(
            PromptDetector.detect(rows: [
                "Allow command?", "1. Always allow", "2. Yes, and don't ask again", "3. No",
            ]))
        #expect(prompt.yes == nil)
        #expect(prompt.no == "3")
        #expect(!prompt.keys.contains("enter"))
        #expect(!prompt.keys.contains("escape"))
    }

    @Test func wrappedInterruptedAndPartialMenusNeverGainVerification() {
        let fixtures = [
            ["Run this long command", "  with wrapped arguments", "Proceed?", "1. Yes", "2. No"],
            ["Proceed?", "1. Yes", "  and always allow this command", "2. No"],
            ["Proceed?", "1. Yes", "^C", "2. No"],
            ["Proceed?", "1. Yes", "2."],
            ["An example approval follows:", "Proceed?", "1. Yes", "2. No"],
        ]
        for rows in fixtures {
            #expect(PromptDetector.detect(rows: rows)?.verified != true)
        }
        #expect(PromptDetector.detect(rows: fixtures[1]) == nil)
        #expect(PromptDetector.detect(rows: fixtures[2]) == nil)
        #expect(PromptDetector.detect(rows: fixtures[3]) == nil)
    }

    @Test func oversizedContextOmitsTheHintInsteadOfTruncatingTheOperation() {
        let command = String(repeating: "x", count: 12_000)
        #expect(PromptDetector.detect(rows: [command, "Proceed?", "1. Yes", "2. No"]) == nil)
    }

    @Test func promptRoundTripsThroughJSON() throws {
        let prompt = RemotePrompt(
            question: "Proceed?", style: .menu, choices: [.init(label: "Yes", key: "1")], yes: "1", no: "escape")
        let data = try JSONEncoder().encode(prompt)
        #expect(try JSONDecoder().decode(RemotePrompt.self, from: data) == prompt)
        #expect(String(decoding: data, as: UTF8.self).contains("\"style\":\"menu\""))
    }
}
