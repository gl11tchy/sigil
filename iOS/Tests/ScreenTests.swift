import Foundation

enum ScreenTests {
    private static func screen(
        _ rows: [(Int, String)], gen: Int = 1, first: Int? = nil, end: Int? = nil, palette: [String]? = nil,
        runs: [Int: [[Int]]] = [:]
    ) -> RemoteScreen {
        RemoteScreen(
            tab: nil, gen: gen, alt: nil, first: first ?? rows.first?.0 ?? 0, end: end ?? ((rows.last?.0 ?? -1) + 1),
            rows: rows.map { RemoteScreenRow(i: $0.0, t: $0.1, w: nil, s: runs[$0.0]) }, palette: palette,
            fg: palette == nil ? nil : "ffffff", bg: palette == nil ? nil : "000000")
    }

    static func modelAppliesWindowsAndDiffs() throws {
        var model = ScreenModel()
        model.apply(screen([(10, "a"), (11, "b"), (12, "c")], palette: Array(repeating: "112233", count: 16)))
        try Expect.equal(model.text, "a\nb\nc", "full window")
        try Expect.equal(model.palette.count, 16, "palette kept")
        model.apply(screen([(11, "B"), (13, "d")], first: 11, end: 14))
        try Expect.equal(model.text, "a\nB\nc\nd", "diff replaces and appends; history stays")
        try Expect.equal(model.palette.count, 16, "palette survives a diff without one")
        model.apply(screen([], first: 11, end: 12))
        try Expect.equal(model.text, "a\nB", "rows past the new end are dropped")
        model.apply(screen([(0, "fresh")], gen: 2))
        try Expect.equal(model.text, "fresh", "a new generation starts over")
    }

    static func modelPrependsOlderRowsUntilExhausted() throws {
        var model = ScreenModel()
        model.apply(screen([(5, "five"), (6, "six")]))
        try Expect.true(model.prepend(screen([(3, "three"), (4, "four")], first: 3, end: 7)), "older rows added")
        try Expect.equal(model.text, "three\nfour\nfive\nsix", "prepended in order")
        try Expect.equal(model.oldestIndex, 3, "oldest index")
        try Expect.true(!model.prepend(screen([(3, "three")], first: 3, end: 7)), "nothing older")
        try Expect.true(model.exhausted, "exhausted after an empty older page")
        try Expect.true(!model.prepend(screen([(1, "one")], gen: 9)), "another generation is ignored")
    }

    static func modelStaysUnderCapAndForgetsOldestFirst() throws {
        var model = ScreenModel()
        let rows = (0..<(ScreenModel.cap + 50)).map { ($0, "r\($0)") }
        model.apply(screen(rows))
        try Expect.equal(model.rows.count, ScreenModel.cap, "capped")
        try Expect.equal(model.oldestIndex, 50, "oldest rows dropped")
    }

    static func wrappedRowsJoinWithoutABreak() throws {
        let lines = [
            ScreenLine(index: 0, text: "long line part "),
            ScreenLine(index: 1, text: "two", wrapped: true),
            ScreenLine(index: 2, text: "next"),
        ]
        try Expect.equal(ScreenModel.text(of: lines), "long line part two\nnext", "wrap joins")
        let raw = StyledOutput.raw(lines + [ScreenLine(index: 3, text: ""), ScreenLine(index: 4, text: "  ")])
        try Expect.equal(raw.text, "long line part two\nnext", "raw text drops the blank rows under the cursor")
    }

    static func rawSpansCountUTF16Units() throws {
        // "é" is one Character, one UTF-16 unit; "😀" is one Character, two units.
        let lines = [
            ScreenLine(index: 0, text: "ab😀cd", runs: [[3, 2, 1, -1, 0]]),
            ScreenLine(index: 1, text: "xy", runs: [[0, 2, -1, 4, 1]]),
        ]
        let styled = StyledOutput.raw(lines)
        try Expect.equal(styled.spans.count, 2, "two spans")
        try Expect.equal(styled.spans[0], StyledSpan(location: 4, length: 2, fg: 1, bg: -1, flags: 0), "after the emoji")
        try Expect.equal(styled.spans[1], StyledSpan(location: 7, length: 2, fg: -1, bg: 4, flags: 1), "second row")
    }

    static func readableSpansFollowKeptLines() throws {
        let lines = [
            ScreenLine(index: 0, text: "│ ERROR here  ", runs: [[2, 5, 1, -1, 1]]),
            ScreenLine(index: 1, text: "plain"),
            ScreenLine(index: 2, text: "GREEN ok", runs: [[0, 5, 2, -1, 0]]),
        ]
        // The formatter dropped the frame from the first line and kept the third as is.
        let formatted = "ERROR here\nplain\nGREEN ok"
        let styled = StyledOutput.readable(formatted, lines: lines)
        try Expect.equal(styled.text, formatted, "text untouched")
        try Expect.equal(styled.spans, [
            StyledSpan(location: 0, length: 5, fg: 1, bg: -1, flags: 1),
            StyledSpan(location: 17, length: 5, fg: 2, bg: -1, flags: 0),
        ], "spans re-based onto the formatted lines")
        // A line the formatter rewrote gets no colour rather than the wrong one.
        let rewritten = StyledOutput.readable("ERROR elsewhere", lines: lines)
        try Expect.equal(rewritten.spans, [], "no match, no spans")
        // Two identical rows in different colours each keep their own.
        let twins = [
            ScreenLine(index: 0, text: "same", runs: [[0, 4, 1, -1, 0]]),
            ScreenLine(index: 1, text: "same", runs: [[0, 4, 2, -1, 0]]),
        ]
        let styled2 = StyledOutput.readable("same\nsame", lines: twins)
        try Expect.equal(styled2.spans.map(\.fg), [1, 2], "each row styles its own line")
    }

    /// A Grok-like screen, 40 columns: ground under every cell, a scrollbar thumb
    /// drawn in its own colour, a two-row prompt panel and a one-row code block.
    private static let ground = RemoteScreen.trueColorBase + 0x141414
    private static let thumb = RemoteScreen.trueColorBase + 0x191919
    private static let prompt = RemoteScreen.trueColorBase + 0x242424
    private static let code = RemoteScreen.trueColorBase + 0x1c1c1c

    private static func grokRow(_ index: Int, _ content: String, panel: Int? = nil, thumbed: Bool = false) -> ScreenLine {
        let width = 40
        let padded = content + String(repeating: " ", count: width - 1 - content.count) + (thumbed ? "█" : " ")
        var runs: [[Int]] = []
        if let panel {
            runs = [[0, 2, -1, ground, 0], [2, content.count - 2, 7, panel, 0], [content.count, 37 - content.count, -1, panel, 0], [37, 2, -1, ground, 0]]
        } else {
            runs = [[0, content.count, 7, ground, 0], [content.count, 39 - content.count, -1, ground, 0]]
        }
        runs.append(thumbed ? [39, 1, thumb, thumb, 0] : [39, 1, -1, ground, 0])
        return ScreenLine(index: index, text: padded, runs: runs)
    }

    static func groundAndScrollbarGoQuiet() throws {
        let lines = [grokRow(0, "  hello", thumbed: true), grokRow(1, ""), grokRow(2, "")]
        let prepared = StyledOutput.prepare(lines)
        try Expect.equal(prepared.ground, ground, "the ground is found")
        try Expect.equal(prepared.lines[0].text, "  hello", "thumb blanked and trailing blanks cut")
        try Expect.equal(prepared.lines[0].runs, [[0, 7, 7, ground, 0]], "runs clipped to the text")
        let raw = StyledOutput.raw(lines)
        try Expect.equal(raw.text, "  hello", "blank rows under the cursor still go")
        try Expect.equal(raw.ground, ground, "the view gets the ground")
        try Expect.equal(raw.spans, [StyledSpan(location: 0, length: 7, fg: 7, bg: -1, flags: 0)], "no ground stripes")
        // Without a ground, a row's own background stays.
        let plain = StyledOutput.raw([ScreenLine(index: 0, text: "ok then", runs: [[0, 2, -1, 4, 0]])])
        try Expect.equal(plain.ground, -1, "no ground on a plain shell")
        try Expect.equal(plain.spans[0].bg, 4, "inline background kept")
    }

    static func panelRowsBecomePanels() throws {
        let lines = [
            grokRow(0, "  header"),
            grokRow(1, "  ❯ ask a question", panel: prompt),
            grokRow(2, "    that wraps", panel: prompt),
            grokRow(3, "  reply"),
            grokRow(4, "  let x = 1", panel: code),
        ]
        let raw = StyledOutput.raw(lines)
        try Expect.equal(raw.text, "  header\n  ❯ ask a question\n    that wraps\n  reply\n  let x = 1", "text")
        try Expect.equal(raw.panels, [
            StyledPanel(location: 9, length: 18, color: prompt, top: true, bottom: false),
            StyledPanel(location: 28, length: 14, color: prompt, top: false, bottom: true),
            StyledPanel(location: 51, length: 11, color: code, top: true, bottom: true),
        ], "one panel run per block, ends marked")
        try Expect.true(raw.spans.allSatisfy { $0.bg == -1 }, "the view paints panels; spans carry no background")
        // Touching panels of two colours stay two panels, even across a soft wrap.
        var wrapped = grokRow(2, "  let y = 2", panel: code)
        wrapped.wrapped = true
        let touching = StyledOutput.raw([grokRow(0, "  header"), grokRow(1, "  ❯ ask", panel: prompt), wrapped])
        try Expect.equal(
            touching.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) },
            ["header", "❯ ask", "let y = 2"], "a continuation in another panel keeps its line")
        try Expect.equal(touching.panels.map(\.color), [prompt, code], "each keeps its colour")
        try Expect.true(touching.panels.allSatisfy { $0.top && $0.bottom }, "each panel has both ends")
        // A short inline background is not a panel.
        let chip = [ScreenLine(index: 0, text: "run `make` now", runs: [[4, 6, 7, 8, 0]]), ScreenLine(index: 1, text: "done")]
        let styledChip = StyledOutput.raw(chip)
        try Expect.equal(styledChip.panels, [], "inline chip")
        try Expect.equal(styledChip.ground, -1, "a colour on some rows is not the ground")
        try Expect.equal(styledChip.spans[0].bg, 8, "the chip keeps its background")
    }

    static func readableLinesDedent() throws {
        // A header, indented less than the rest, with a status after a long gap.
        let header = ScreenLine(
            index: 0, text: "  top" + String(repeating: " ", count: 19) + "9:00" + String(repeating: " ", count: 12),
            runs: [[0, 5, 7, ground, 0], [5, 19, -1, ground, 0], [24, 4, 8, ground, 0], [28, 12, -1, ground, 0]])
        let lines = [
            header,
            grokRow(1, "     ❯ ask", panel: prompt),
        ] + (2..<12).map { grokRow($0, "     line \($0)") }
            + [grokRow(12, "     let a", panel: code), grokRow(13, ""), grokRow(14, "     let b", panel: code)]
        let prepared = StyledOutput.prepare(lines)
        let styled = StyledOutput.readable(ScreenModel.text(of: prepared.lines), screen: prepared)
        let out = styled.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try Expect.equal(out[0], "top" + String(repeating: " ", count: 19) + "9:00", "a shallower header goes to the margin; inner spacing stays")
        try Expect.equal(out[1], "❯ ask", "the shared indent goes")
        try Expect.equal(out[2], "line 2", "body dedented")
        try Expect.equal(Array(out.suffix(3)), ["let a", "", "let b"], "code dedented")
        try Expect.equal(styled.spans.first, StyledSpan(location: 0, length: 3, fg: 7, bg: -1, flags: 0), "span follows the dedent")
        let status = styled.spans.first { $0.fg == 8 }
        try Expect.equal(status?.location, 22, "span after the gap moves with the dedent")
        let block = styled.panels.filter { $0.color == code }
        try Expect.equal(block.count, 3, "a blank line inside a code block joins it")
        try Expect.true(block[0].top && !block[0].bottom && block[2].bottom, "one run")

        let short = StyledOutput.prepare([header] + (1..<5).map { grokRow($0, "     line \($0)") })
        let few = StyledOutput.readable(ScreenModel.text(of: short.lines), screen: short).text
        try Expect.equal(few.split(separator: "\n").last.map(String.init), "line 4", "one header does not hold a short screen")
    }

    static func wrappedLinesHangAfterTheirMarker() throws {
        try Expect.equal(StyledOutput.hangingPrefix("• item text"), 2, "bullet")
        try Expect.equal(StyledOutput.hangingPrefix("   ◆ hook failed"), 5, "indented diamond")
        try Expect.equal(StyledOutput.hangingPrefix("12. step"), 4, "numbered")
        try Expect.equal(StyledOutput.hangingPrefix("  ⎿  result"), 5, "tool result")
        try Expect.equal(StyledOutput.hangingPrefix("✅ DONE — ok"), 2, "emoji marker")
        try Expect.equal(StyledOutput.hangingPrefix("-rw-r--r-- file"), 0, "a dash without a space is text")
        try Expect.equal(StyledOutput.hangingPrefix("    plain"), 4, "indent only")
        try Expect.equal(StyledOutput.hangingPrefix(String(repeating: " ", count: 30) + "x"), 16, "capped")
    }

    static func coloursResolveThroughThePalette() throws {
        let palette = (0..<16).map { String(format: "%02x%02x%02x", $0, $0, $0) }
        try Expect.equal(StyledOutput.rgb(-1, palette: palette), nil, "default")
        try Expect.equal(StyledOutput.rgb(3, palette: palette), 0x030303, "theme colour")
        try Expect.equal(StyledOutput.rgb(16, palette: palette), 0x000000, "cube start")
        try Expect.equal(StyledOutput.rgb(231, palette: palette), 0xffffff, "cube end")
        try Expect.equal(StyledOutput.rgb(232, palette: palette), 0x080808, "first grey")
        try Expect.equal(StyledOutput.rgb(RemoteScreen.trueColorBase + 0x123456, palette: palette), 0x123456, "true colour")
        try Expect.equal(StyledOutput.rgb(3, palette: []), nil, "no palette, no colour")
        try Expect.equal(StyledOutput.rgb(300, palette: palette), nil, "out of range")
    }

    static func decodesAnEventWithAScreen() throws {
        let json = """
            {"challenge":"c","sequence":0,"event":true,"state":{"tabs":[{"id":"T1","title":"t","status":"working",
            "provider":"claudeCode","providerName":"Claude Code","folder":"sigil","canArchive":false}],
            "selectedTabID":"T1","terminal":"","capabilities":["restart","screen","sessionOps"],"mac":"Studio",
            "screen":{"gen":3,"first":100,"end":102,"rows":[{"i":100,"t":"hi","s":[[0,2,1,-1,1]]},{"i":101,"t":"x","w":true}]}}}
            """
        let reply = try JSONDecoder().decode(RemoteReply.self, from: Data(json.utf8))
        try Expect.equal(reply.event, true, "event flag")
        let state = try Expect.notNil(reply.state, "state")
        try state.validate()
        try Expect.true(state.streamsScreen && state.supportsSessionOps, "capabilities")
        try Expect.equal(state.mac, "Studio", "mac name")
        try Expect.equal(state.screen?.tab, nil, "older Macs send no tab on a screen")
        try Expect.equal(state.tabs[0].providerName, "Claude Code", "provider name")
        try Expect.equal(state.tabs[0].canArchive, false, "archive flag")
        let screen = try Expect.notNil(state.screen, "screen")
        try Expect.equal(screen.rows[0].s, [[0, 2, 1, -1, 1]], "runs")
        try Expect.equal(screen.rows[1].w, true, "wrapped")
        // Cached tabs round-trip with their status word.
        let encoded = try JSONEncoder().encode(state.tabs)
        let back = try JSONDecoder().decode([RemoteTab].self, from: encoded)
        try Expect.equal(back, state.tabs, "tab cache round trip")
    }

    static func rejectsAMalformedScreen() throws {
        let json = """
            {"challenge":"c","sequence":0,"event":true,"state":{"tabs":[],"selectedTabID":null,"terminal":"",
            "screen":{"gen":1,"first":5,"end":3,"rows":[]}}}
            """
        let reply = try JSONDecoder().decode(RemoteReply.self, from: Data(json.utf8))
        try Expect.true((try? reply.state?.validate()) == nil, "end before first is rejected")
        let badRun = """
            {"challenge":"c","sequence":0,"state":{"tabs":[],"selectedTabID":null,"terminal":"",
            "screen":{"gen":1,"first":0,"end":1,"rows":[{"i":0,"t":"a","s":[[0,1]]}]}}}
            """
        let short = try JSONDecoder().decode(RemoteReply.self, from: Data(badRun.utf8))
        try Expect.true((try? short.state?.validate()) == nil, "a run needs five numbers")
    }

    static func decodesAPrompt() throws {
        let json = """
            {"challenge":"c","sequence":1,"state":{"tabs":[],"selectedTabID":null,"terminal":"",
            "prompt":{"id":"abc123","question":"Do you want to proceed?","style":"menu","yes":"1","no":"3",
            "choices":[{"label":"Yes","key":"1"},{"label":"Yes, always","key":"2"},{"label":"No (esc)","key":"3"}]}}}
            """
        let reply = try JSONDecoder().decode(RemoteReply.self, from: Data(json.utf8))
        let state = try Expect.notNil(reply.state, "state")
        try state.validate()
        let prompt = try Expect.notNil(state.prompt, "prompt")
        try Expect.equal(prompt.style, .menu, "style")
        try Expect.equal(prompt.id, "abc123", "id")
        try Expect.equal(prompt.choices.map(\.key), ["1", "2", "3"], "keys")
        try Expect.equal(prompt.yes, "1", "yes")
        let odd = json.replacingOccurrences(of: "\"menu\"", with: "\"wheel\"")
        let unknown = try JSONDecoder().decode(RemoteReply.self, from: Data(odd.utf8))
        try Expect.equal(unknown.state?.prompt?.style, .unknown("wheel"), "an unknown style is kept as is")
        let tooMany = json.replacingOccurrences(
            of: "{\"label\":\"Yes\",\"key\":\"1\"},",
            with: String(repeating: "{\"label\":\"x\",\"key\":\"9\"},", count: 8))
        let crowded = try JSONDecoder().decode(RemoteReply.self, from: Data(tooMany.utf8))
        try Expect.true((try? crowded.state?.validate()) == nil, "ten choices are rejected")
    }

    /// The notification extension opens an alert with any paired Mac's key and
    /// never with a reply's direction.
    static func alertOpensWithTheRightKeyOnly() throws {
        let right = RemoteCrypto.randomKey()
        let wrong = RemoteCrypto.randomKey()
        let alert = RemoteAlert(kind: .asking, tabID: "T1", title: "sigil", body: "Do you want to proceed?")
        let sealed = try RemoteCrypto.seal(alert, key: right, direction: RemoteAlert.direction)
        try Expect.equal(RemoteAlert.open(sealed, keys: [wrong, right]), alert, "second key opens it")
        try Expect.equal(RemoteAlert.open(sealed, keys: [wrong]), nil, "wrong key")
        try Expect.equal(RemoteAlert.open(sealed, keys: []), nil, "no keys")
        let reply = try RemoteCrypto.seal(alert, key: right, direction: "mac")
        try Expect.equal(RemoteAlert.open(reply, keys: [right]), nil, "a reply is not an alert")
        let odd = try JSONDecoder().decode(
            RemoteAlert.self, from: Data("{\"kind\":\"nudge\",\"tabID\":\"T\",\"title\":\"t\",\"body\":\"\"}".utf8))
        try Expect.equal(odd.kind, .unknown("nudge"), "unknown kinds are kept")
        try Expect.equal(odd.shownBody, "A session needs you.", "and get a plain body")
        try Expect.equal(RemoteAlert(kind: .finished, tabID: "T", title: "t", body: "").shownBody, "Finished and waiting for you.", "finished body")
    }

    static func pairingListRules() throws {
        let origin = URL(string: "https://remote.example")!
        let a = PairingCredential(id: "a", origin: origin, room: String(repeating: "0", count: 32), deviceKey: String(repeating: "ab", count: 32), ticket: nil, name: "Studio")
        let b = PairingCredential(id: "b", origin: origin, room: String(repeating: "1", count: 32), deviceKey: String(repeating: "cd", count: 32), ticket: nil)
        var list = PairingList()
        try Expect.equal(list.selected, nil, "empty list")
        list.upsert(a)
        list.upsert(b)
        try Expect.equal(list.selected?.id, "b", "a new Mac is selected")
        var renamed = a
        renamed.name = "Studio 2"
        list.upsert(renamed, select: false)
        try Expect.equal(list.macs.map(\.name), ["Studio 2", nil], "upsert replaces by id in place")
        try Expect.equal(list.selectedID, "b", "select false keeps the selection")
        list.remove(id: "b")
        try Expect.equal(list.selectedID, "a", "selection moves when the selected Mac goes")
        list.remove(id: "a")
        try Expect.equal(list.selected, nil, "nothing left")
        try Expect.equal(b.label, "remote.example", "no name shows the host")
        try Expect.equal(a.label, "Studio", "name wins")
        // A pairing saved before ids decodes with a fresh one; the round trip keeps it.
        let old = Data("{\"origin\":\"https://remote.example\",\"room\":\"\(String(repeating: "0", count: 32))\",\"deviceKey\":\"\(String(repeating: "ab", count: 32))\"}".utf8)
        let decoded = try JSONDecoder().decode(PairingCredential.self, from: old)
        try Expect.true(!decoded.id.isEmpty && decoded.isValid, "legacy pairing gets an id")
        let again = try JSONDecoder().decode(PairingCredential.self, from: try JSONEncoder().encode(decoded))
        try Expect.equal(again.id, decoded.id, "id survives a round trip")
    }

    static func alertNamesTheMacThatSentIt() throws {
        let keys = [RemoteCrypto.randomKey(), RemoteCrypto.randomKey()]
        let alert = RemoteAlert(kind: .ended, tabID: "T", title: "sigil", body: "")
        let sealed = try RemoteCrypto.seal(alert, key: keys[1], direction: RemoteAlert.direction)
        let opened = try Expect.notNil(RemoteAlert.opened(sealed, keys: keys), "opens")
        try Expect.equal(opened.keyIndex, 1, "the second Mac's key")
        try Expect.equal(opened.alert, alert, "same alert")
    }

    static func requestCarriesWorktree() throws {
        var request = RemoteRequest(challenge: "c", sequence: 1, action: "new")
        request.worktree = true
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try Expect.true(json.contains("\"worktree\":true"), "worktree sent")
        let plain = String(decoding: try JSONEncoder().encode(RemoteRequest(challenge: "c", sequence: 1, action: "new")), as: UTF8.self)
        try Expect.true(!plain.contains("worktree"), "absent when unset")
    }
}
