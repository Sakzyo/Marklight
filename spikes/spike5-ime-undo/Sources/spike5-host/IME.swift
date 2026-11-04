import AppKit
import EditCore
import EditScenarios

/// What an input method does, sent through `NSTextInputClient`, the interface a
/// real IME uses. WebKit can't tell the difference, but the input method's own
/// behavior (candidate window, Escape, clause conversion) isn't exercised.
enum IME {
    case mark(String)
    case commit(String)
    case cancel
    case key(String, UInt16)
    case undo
    case redo
    case remote(at: Int, text: String)
    case checkBufferIs(String)
}

let notFound = NSRange(location: NSNotFound, length: 0)

let imeCases: [(name: String, before: String, steps: [IME], after: String)] = [
    ("pinyin in a paragraph", "你‸世界\n", [.mark("h"), .mark("ha"), .mark("hao"), .commit("好")], "你好‸世界\n"),
    ("pinyin at document start", "‸abc\n", [.mark("n"), .mark("ni"), .commit("你")], "你‸abc\n"),
    ("pinyin at the end of a paragraph", "abc‸\n\nnext\n", [.mark("n"), .mark("ni"), .commit("你")], "abc你‸\n\nnext\n"),
    ("candidate changes before commit", "a‸b\n", [.mark("nihao"), .mark("你好"), .mark("拟好"), .commit("你好")], "a你好‸b\n"),
    ("Japanese romaji then conversion", "a‸b\n", [.mark("k"), .mark("か"), .mark("かん"), .mark("かんじ"), .mark("漢字"), .commit("漢字")], "a漢字‸b\n"),
    ("two compositions in a row", "‸\n\nx\n".replacingOccurrences(of: "‸\n\nx", with: "a‸\n\nx"), [.mark("ni"), .commit("你"), .mark("hao"), .commit("好")], "a你好‸\n\nx\n"),
    ("composition then ordinary typing", "a‸\n", [.mark("ni"), .commit("你"), .key("b", 0)], "a你b‸\n"),
    ("ordinary typing then composition", "a‸\n", [.key("b", 0), .mark("ni"), .commit("你")], "ab你‸\n"),
    ("commit then Enter", "a‸b\n", [.mark("ni"), .commit("你"), .key("\r", 36)], "a你\n\n‸b\n"),
    ("commit then Backspace", "a‸b\n", [.mark("ni"), .commit("你"), .key("\u{7F}", 51)], "a‸b\n"),
    ("inside bold", "**a‸b**\n", [.mark("ni"), .commit("你")], "**a你‸b**\n"),
    ("at the start inside bold", "x **‸b**\n", [.mark("ni"), .commit("你")], "x **你‸b**\n"),
    ("before bold", "x‸**b**\n", [.mark("ni"), .commit("你")], "x你‸**b**\n"),
    ("inside inline code", "`a‸b`\n", [.mark("ni"), .commit("你")], "`a你‸b`\n"),
    ("inside a link", "[a‸b](/u)\n", [.mark("ni"), .commit("你")], "[a你‸b](/u)\n"),
    ("in a heading", "# a‸b\n", [.mark("ni"), .commit("你")], "# a你‸b\n"),
    ("in a list item", "- a‸b\n- c\n", [.mark("ni"), .commit("你")], "- a你‸b\n- c\n"),
    ("in a quote", "> a‸b\n", [.mark("ni"), .commit("你")], "> a你‸b\n"),
    ("in a table cell", "| a‸ |\n|---|\n| b |\n", [.mark("ni"), .commit("你")], "| a你‸ |\n|---|\n| b |\n"),
    ("in an empty table cell", "| a |\n|---|\n| ‸ |\n", [.mark("ni"), .commit("你")], "| a |\n|---|\n| 你‸ |\n"),
    ("in a code block", "```\na‸b\n```\n", [.mark("ni"), .commit("你")], "```\na你‸b\n```\n"),
    ("in an empty list item", "- a\n- ‸\n", [.mark("ni"), .commit("你")], "- a\n- 你‸\n"),
    ("in a new empty paragraph", "a‸\n", [.key("\r", 36), .mark("ni"), .commit("你")], "a\n\n你‸\n"),
    ("replacing a selection", "a⟦bc⟧d\n", [.mark("ni"), .commit("你")], "a你‸d\n"),
    ("replacing a selection across a mark", "a⟦b **c⟧d**\n", [.mark("ni"), .commit("你")], "a你‸**d**\n"),
    ("replacing a selection across blocks", "ab⟦c\n\nd⟧ef\n\nx\n", [.mark("ni"), .commit("你")], "ab你‸ef\n\nx\n"),
    ("cancel over a selection across blocks restores both", "ab⟦c\n\nd⟧ef\n\nx\n", [.mark("ni"), .cancel], "ab⟦c\n\nd⟧ef\n\nx\n"),
    ("composition across list items", "- a⟦b\n- c⟧d\n", [.mark("ni"), .commit("你")], "- a你‸d\n"),
    ("step 13: compose on a new line, delete it, delete the line", "a‸\n", [.key("\r", 36), .mark("ni"), .commit("你"), .key("\u{7F}", 51), .key("\u{7F}", 51)], "a‸\n"),
    ("step 13: two characters, then the line", "a‸\n\nb\n", [.key("\r", 36), .mark("nihao"), .commit("你好"), .key("\u{7F}", 51), .key("\u{7F}", 51), .key("\u{7F}", 51)], "a‸\n\nb\n"),
    ("step 13: compose again after deleting", "a‸\n", [.key("\r", 36), .mark("ni"), .commit("你"), .key("\u{7F}", 51), .mark("hao"), .commit("好")], "a\n\n好‸\n"),
    ("step 13: cancel, then delete the line", "a‸\n", [.key("\r", 36), .mark("ni"), .cancel, .key("\u{7F}", 51)], "a‸\n"),
    ("delete the only text of a heading", "# 你‸\n", [.key("\u{7F}", 51)], "# ‸\n"),
    ("delete a composed list item, then leave the list", "- a\n- ‸\n", [.mark("ni"), .commit("你"), .key("\u{7F}", 51), .key("\u{7F}", 51)], "- a\n\n‸\n"),
    ("committed specials stay literal", "x *a‸\n", [.mark("x"), .commit("*")], "x *a\\*‸\n"),
    ("committing emoji", "a‸b\n", [.mark("x"), .commit("🎉")], "a🎉‸b\n"),
    ("CRLF document", "a‸b\r\n\r\nc\r\n", [.mark("ni"), .commit("你")], "a你‸b\r\n\r\nc\r\n"),

    ("cancel leaves the buffer alone", "a‸b\n", [.mark("ni"), .mark("nih"), .cancel], "a‸b\n"),
    ("cancel with a selection keeps it", "a⟦bc⟧d\n", [.mark("ni"), .cancel], "a⟦bc⟧d\n"),
    ("cancel in an empty paragraph", "a‸\n", [.key("\r", 36), .mark("ni"), .cancel, .mark("hao"), .commit("好")], "a\n\n好‸\n"),
    ("cancel then type", "a‸b\n", [.mark("ni"), .cancel, .key("c", 0)], "ac‸b\n"),

    ("buffer doesn't change mid-composition", "a‸b\n", [.mark("n"), .checkBufferIs("ab\n"), .mark("ni"), .checkBufferIs("ab\n"), .commit("你")], "a你‸b\n"),
    ("one undo removes one composition", "a‸b\n", [.key("c", 0), .mark("ni"), .commit("你"), .undo], "ac‸b\n"),
    ("undo then redo a composition", "a‸b\n", [.mark("ni"), .commit("你"), .undo, .redo], "a你‸b\n"),

    ("source edit above during composition", "x\n\na‸b\n", [.mark("ni"), .remote(at: 0, text: "yy"), .commit("你")], "yyx\n\na你‸b\n"),
    ("source edit below during composition", "a‸b\n\nx\n", [.mark("ni"), .remote(at: 4, text: "yy"), .commit("你")], "a你‸b\n\nyyx\n"),
    ("source edit in the composing block", "a‸b\n", [.mark("ni"), .remote(at: 0, text: "yy"), .commit("你")], "yya你‸b\n"),
    ("source edit after the caret in the composing block", "a‸bcd\n", [.mark("ni"), .remote(at: 3, text: "yy"), .commit("你")], "a你‸bcyyd\n"),
    ("source edit in the composing block, then cancel", "a‸b\n", [.mark("ni"), .remote(at: 0, text: "yy"), .cancel], "yya‸b\n"),
]

@MainActor func imeTests(_ host: Host) async -> Bool {
    guard let client = host.webView as Any as? NSTextInputClient else {
        print("WKWebView doesn't expose NSTextInputClient")
        return false
    }
    var passed = 0, failed: [String] = []
    var seen: [String: Int] = [:]
    for t in imeCases {
        let (text, selection) = parseMarkers(t.before)
        let (expected, expectedSel) = parseMarkers(t.after)
        await host.load(text, selection: selection)
        await host.settle()
        host.window.makeFirstResponder(host.webView)
        var note = ""
        for step in t.steps {
            switch step {
            case .mark(let s):
                client.setMarkedText(s, selectedRange: NSRange(location: (s as NSString).length, length: 0), replacementRange: notFound)
            case .commit(let s):
                client.insertText(s, replacementRange: notFound)
            case .cancel:
                client.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: notFound)
                client.unmarkText()
            case .key(let chars, let code):
                host.key(chars, code: code)
            case .undo:
                host.key("z", code: 6, flags: .command)
            case .redo:
                host.key("z", code: 6, flags: [.command, .shift])
            case .remote(let at, let s):
                host.textView.textStorage?.replaceCharacters(in: NSRange(location: at, length: 0), with: s)
            case .checkBufferIs(let s):
                if host.editor.text != s { note += " buffer changed mid-composition: \(host.editor.text.debugDescription)" }
            }
            await host.settle()
        }
        let caret: [Int] = await host.js("return marklight.selection()") ?? []
        let visual = host.visualCaret(expectedSel.lowerBound)
        let caretOK = caret == [expectedSel.lowerBound, expectedSel.upperBound] || caret == [visual, visual]
        let bad = await host.verifyDOM()
        let mirrored = host.textView.string.utf8.elementsEqual(host.editor.text.utf8)
        let textOK = host.editor.text.utf8.elementsEqual(expected.utf8)
        let trace: [String] = await host.js("return marklight.trace()") ?? []
        for line in trace { seen[String(line.split(separator: " ").prefix(2).joined(separator: " ").prefix(40)), default: 0] += 1 }
        if textOK, caretOK, bad == nil, mirrored, note.isEmpty {
            passed += 1
        } else {
            failed.append("\(t.name)\n     got  \(host.editor.text.debugDescription) caret \(caret)\n     want \(expected.debugDescription) caret \(expectedSel)\n     dom \(bad?.prefix(160) ?? "ok"), source \(mirrored)\(note)\n     trace \(trace.joined(separator: " | ").prefix(240))")
        }
    }
    print("\nIME protocol tests: \(passed) passed, \(failed.count) failed")
    for f in failed { print("FAIL \(f)") }
    let beforeInputs = seen.filter { $0.key.hasPrefix("beforeinput") }.sorted { $0.key < $1.key }
    print("beforeinput types during composition: \(beforeInputs.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))")
    return failed.isEmpty
}

/// Undo across panes through real Cmd-Z key events.
@MainActor func undoTests(_ host: Host) async {
    var rows: [(String, Bool, String)] = []
    func add(_ name: String, _ ok: Bool, _ detail: String = "") {
        rows.append((name, ok, detail))
        print("\(ok ? "pass" : "FAIL")  \(name)  \(detail)")
    }
    func cmdZ(shift: Bool = false) async {
        host.key("z", code: 6, flags: shift ? [.command, .shift] : .command)
        await host.settle()
    }
    func checkPanes() async -> Bool {
        let bad = await host.verifyDOM()
        if let bad { print("     DOM: \(bad.prefix(200))") }
        return bad == nil && host.textView.string.utf8.elementsEqual(host.editor.text.utf8)
    }
    func pause() async { try? await Task.sleep(nanoseconds: 1_100_000_000) }

    let text = "one\n\ntwo\n\nthree\n"
    await host.load(text, selection: 3..<3)
    host.window.makeFirstResponder(host.webView)
    host.key("x", code: 0)
    await host.settle()
    await pause()
    host.textView.setSelectedRange(NSRange(location: 9, length: 0))
    host.window.makeFirstResponder(host.textView)
    host.key("y", code: 0)
    await host.settle()
    add("edits from both panes land", host.editor.text == "onex\n\ntwoy\n\nthree\n", host.editor.text.debugDescription)

    await cmdZ()
    add("Cmd-Z in the source pane undoes the source edit", host.editor.text == "onex\n\ntwo\n\nthree\n")
    await cmdZ()
    add("Cmd-Z in the source pane undoes the rendered edit", host.editor.text == text)
    add("both panes agree", await checkPanes())
    await cmdZ(shift: true)
    await cmdZ(shift: true)
    add("Cmd-Shift-Z redoes both from the source pane", host.editor.text == "onex\n\ntwoy\n\nthree\n")

    host.window.makeFirstResponder(host.webView)
    let _: Bool? = await host.js("marklight.focusRoot(); marklight.select(1, 1); return true")
    await cmdZ()
    add("Cmd-Z in the rendered pane undoes the source edit", host.editor.text == "onex\n\ntwo\n\nthree\n")
    let sel: [Int] = await host.js("return marklight.selection()") ?? []
    add("the caret goes to the undone edit", sel == [9, 9], "\(sel)")
    await cmdZ()
    add("Cmd-Z in the rendered pane undoes the rendered edit", host.editor.text == text)
    add("undoing everything restores the original bytes", host.editor.text.utf8.elementsEqual(text.utf8))
    add("both panes agree", await checkPanes())
    await cmdZ()
    add("Cmd-Z with nothing to undo does nothing", host.editor.text == text)
    await cmdZ(shift: true)
    await cmdZ(shift: true)
    add("Cmd-Shift-Z redoes both from the rendered pane", host.editor.text == "onex\n\ntwoy\n\nthree\n")
    add("both panes agree", await checkPanes())

    // Native undo must have nothing of its own to do.
    await host.load("a‸b\n".replacingOccurrences(of: "‸", with: ""), selection: 1..<1)
    host.window.makeFirstResponder(host.webView)
    host.key("x", code: 0)
    await host.settle()
    host.key("\r", code: 36)
    await host.settle()
    host.key("\u{7F}", code: 51)
    await host.settle()
    let afterKeys = host.editor.text
    await cmdZ()
    await cmdZ()
    await cmdZ()
    add("three structural steps undo to the original", host.editor.text == "ab\n", "\(afterKeys.debugDescription) to \(host.editor.text.debugDescription)")
    add("both panes agree", await checkPanes())

    // A long mixed session
    var rng = SystemRandomNumberGenerator()
    let start = "# Title\n\nFirst *paragraph* here.\n\n- one\n- two\n\nLast one.\n"
    await host.load(start, selection: 10..<10)
    for i in 0..<120 {
        let n = host.editor.units.count
        if i % 3 == 0 {
            host.window.makeFirstResponder(host.textView)
            host.textView.setSelectedRange(NSRange(location: Int.random(in: 0..<n, using: &rng), length: 0))
            host.key("s", code: 0)
        } else {
            host.window.makeFirstResponder(host.webView)
            let leaves = host.editor.doc.root.allLeaves().filter { !$0.opaque && !$0.atoms.isEmpty }
            if let leaf = leaves.randomElement(using: &rng), let at = leaf.atoms.randomElement(using: &rng)?.range?.lowerBound {
                let _: Bool? = await host.js("marklight.focusRoot(); marklight.select(a, a); return true", ["a": at])
                switch i % 4 {
                case 0: host.key("\r", code: 36)
                case 1: host.key("\u{7F}", code: 51)
                default: host.key("r", code: 0)
                }
            }
        }
        await host.settle()
    }
    let finalText = host.editor.text
    var undos = 0
    while host.editor.canUndo {
        await cmdZ()
        undos += 1
    }
    add("mixed session: undo all restores the original bytes", host.editor.text.utf8.elementsEqual(start.utf8), "\(undos) steps")
    add("mixed session: panes agree after undo", await checkPanes())
    while host.editor.canRedo { await cmdZ(shift: true) }
    add("mixed session: redo all restores the result", host.editor.text.utf8.elementsEqual(finalText.utf8))
    add("mixed session: panes agree after redo", await checkPanes())
    print("\nundo: \(rows.filter { $0.1 }.count) passed, \(rows.filter { !$0.1 }.count) failed")
}
