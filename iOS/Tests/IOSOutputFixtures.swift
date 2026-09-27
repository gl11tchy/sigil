import Foundation

/// Random, repeatable screens for the output tests: prose and list rows, panel
/// rows, blank rows, soft wraps, a scrollbar thumb, multi-byte text and Grok's composer.
enum IOSOutputFixtures {
    /// SplitMix64, so a failing seed reproduces.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let width = 40
    static let ground = RemoteScreen.trueColorBase + 0x141414
    static let thumb = RemoteScreen.trueColorBase + 0x191919
    static let panelColors = [RemoteScreen.trueColorBase + 0x242424, RemoteScreen.trueColorBase + 0x1c1c1c]
    static let palette = (0..<16).map { String(format: "%06x", $0 * 0x0F0F0F) }
    static let words = [
        "ok", "build", "café", "naïve", "😀", "日本語", "e\u{301}te\u{301}", "👩‍👩‍👧", "résumé", "λ", "→",
        "let", "x", "=", "1;", "Finished", "The", "mobile", "layout", "tests", "Ünïcödé", "🇸🇪", "│",
    ]
    /// An idle Grok composer; the readable formatter cuts it from the end.
    static let footer = [
        "", String(repeating: "─", count: 38), "│ ❯ Build anything", "                 Grok 4.6",
        "(xhigh) · always-approve", "", "→:expand | Ctrl+e:collapse thinking | Ctrl+x:shortcuts",
    ]

    static func text(using rng: inout Seeded) -> String {
        let indent = String(repeating: " ", count: [0, 2, 2, 4, 5, 6][Int.random(in: 0..<6, using: &rng)])
        let marker = ["", "", "", "• ", "❯ ", "1. ", "⎿  ", "- "][Int.random(in: 0..<8, using: &rng)]
        let body = (0..<Int.random(in: 1...6, using: &rng)).map { _ in words.randomElement(using: &rng)! }
        let capital = Bool.random(using: &rng) ? "Then " : ""
        return String((indent + marker + capital + body.joined(separator: " ")).prefix(width - 2))
    }

    /// One row, styled as a Grok-like program paints it when `grounded`. `kind` 0 is
    /// blank, 1 and 2 are panels, 3 is a soft wrap; random when nil.
    static func row(_ index: Int, grounded: Bool, kind: Int? = nil, using rng: inout Seeded) -> RemoteScreenRow {
        let kind = kind ?? Int.random(in: 0..<12, using: &rng)
        var content = kind == 0 ? "" : text(using: &rng)
        var runs: [[Int]] = []
        let background = grounded ? ground : -1
        if kind == 1 || kind == 2 {
            // A panel: the program paints its colour across the width.
            let panel = panelColors[kind - 1]
            content += String(repeating: " ", count: max(width - 2 - content.count, 0))
            runs = [[0, width - 2, Int.random(in: -1..<16, using: &rng), panel, 0]]
        } else if !content.isEmpty {
            // Two or three runs over the row, some without colour.
            let count = content.count
            var cuts = Set([0, count])
            for _ in 0..<Int.random(in: 0...2, using: &rng) { cuts.insert(Int.random(in: 0...count, using: &rng)) }
            let edges = cuts.sorted()
            for (start, end) in zip(edges, edges.dropFirst()) where end > start {
                let fg = [-1, 1, 2, 7, 12, 200, RemoteScreen.trueColorBase + 0xE0A030][Int.random(in: 0..<7, using: &rng)]
                let bg = Int.random(in: 0..<8, using: &rng) == 0 ? 4 : background
                let flags = [0, 0, 0, StyledSpan.bold, StyledSpan.dim, StyledSpan.italic, StyledSpan.inverse,
                    StyledSpan.underline | StyledSpan.crossedOut][Int.random(in: 0..<8, using: &rng)]
                if fg < 0 && bg < 0 && flags == 0 { continue }
                runs.append([start, end - start, fg, bg, flags])
            }
        }
        if Int.random(in: 0..<8, using: &rng) == 0 {
            // A scrollbar thumb at the right edge, drawn in its own colour.
            let used = content.count
            content += String(repeating: " ", count: max(width - 1 - used, 0)) + "█"
            runs.append([content.count - 1, 1, thumb, thumb, 0])
        }
        let wrapped = kind == 3 && index > 0
        return RemoteScreenRow(i: index, t: content, w: wrapped ? true : nil, s: runs.isEmpty ? nil : runs)
    }

    static func footerRows(from index: Int) -> [RemoteScreenRow] {
        footer.enumerated().map { RemoteScreenRow(i: index + $0.offset, t: $0.element, w: nil, s: nil) }
    }

    static func screen(
        gen: Int, first: Int, end: Int, rows: [RemoteScreenRow], palette: [String]? = IOSOutputFixtures.palette
    ) -> RemoteScreen {
        RemoteScreen(
            tab: nil, gen: gen, alt: nil, first: first, end: end, rows: rows, palette: palette,
            fg: palette == nil ? nil : "e0e0e0", bg: palette == nil ? nil : "101010")
    }

    /// A fresh screen of `count` rows.
    static func model(count: Int, grounded: Bool, footer: Bool, from base: Int = 0, using rng: inout Seeded)
        -> ScreenModel
    {
        var rows = (base..<(base + count)).map { row($0, grounded: grounded, using: &rng) }
        if footer { rows += footerRows(from: base + count) }
        var model = ScreenModel()
        model.apply(screen(gen: 1, first: base, end: base + rows.count, rows: rows))
        return model
    }

    static func formatter() throws -> ReadableOutput {
        let formatter = ReadableOutput(script: try String(contentsOfFile: "Sigil/Resources/readable-output.js", encoding: .utf8))
        try Expect.true(formatter.isAvailable, "script loaded")
        return formatter
    }
}
