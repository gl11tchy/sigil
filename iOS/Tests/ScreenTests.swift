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

    static func requestCarriesWorktree() throws {
        var request = RemoteRequest(challenge: "c", sequence: 1, action: "new")
        request.worktree = true
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try Expect.true(json.contains("\"worktree\":true"), "worktree sent")
        let plain = String(decoding: try JSONEncoder().encode(RemoteRequest(challenge: "c", sequence: 1, action: "new")), as: UTF8.self)
        try Expect.true(!plain.contains("worktree"), "absent when unset")
    }
}
