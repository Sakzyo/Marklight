import AppKit
import Foundation
import MarklightCore
import Testing
import WebKit
@testable import MarklightApp

/// WebKit ignores ordinary keys in the test process's inactive window.
private final class RenderedKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private struct LeafScenario: Decodable {
    let before: String
    let inputType: String
    let data: String?
    let after: String
}

/// Markers denote source offsets, even when an emoji or CRLF precedes one.
private func unpack(_ marked: String) -> (text: String, selection: [Int]) {
    var units: [UInt16] = []
    var start = 0, end = 0
    for unit in marked.utf16 {
        switch unit {
        case 0x2038: start = units.count; end = start
        case 0x27E6: start = units.count
        case 0x27E7: end = units.count
        default: units.append(unit)
        }
    }
    return (String(decoding: units, as: UTF16.self), [start, end])
}

@MainActor private func key(_ h: PreviewHarness, _ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: h.window.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        h.window.sendEvent(e)
    }
}

@MainActor private func beginEditing(_ h: PreviewHarness, at selection: [Int]) async throws {
    try await h.settle()
    h.window.makeFirstResponder(h.webView)
    _ = try await h.js("""
    document.getElementById('doc').focus();
    marklight.select(start, end);
    window.acks = 0;
    const done = marklight.done;
    marklight.done = () => { window.acks++; done(); };
    """, ["start": selection[0], "end": selection[1]])
}

/// Waiting on updater.isCurrent alone can succeed before WebKit sends its key.
@MainActor private func waitForAck(_ h: PreviewHarness, _ expected: Int) async throws {
    let until = Date().addingTimeInterval(4)
    repeat {
        if let n = try await h.js("return window.acks") as? Int, n >= expected {
            try await h.settle()
            return
        }
        await pump(for: 0.01)
    } while Date() < until
    throw HarnessFailure(description: "no WebKit acknowledgment \(expected), buffer \(h.doc.buffer.text.debugDescription), rejected \(h.pane.rejectedMessages)")
}

/// Compare the live DOM to HTML produced by an independent full parse. Do this
/// after observing the live caret and node identity; load replaces their nodes.
@MainActor private func checkFresh(_ h: PreviewHarness) async throws {
    let live = try await h.dom()
    let selection = try await h.js("return marklight.selection()") as? [Int]
    let full = HTMLRenderer.render(ParsedDocument(units: h.doc.buffer.units))
    let list = full.blocks.map { ["html": $0.html, "base": $0.base] as [String: Any] }
    _ = try await h.js("marklight.load(list, v, start, end)", [
        "list": list, "v": h.doc.buffer.version, "start": selection?.first as Any? ?? NSNull(), "end": selection?.last as Any? ?? NSNull(),
    ])
    #expect(try await h.dom() == live)
    #expect(Array(h.textView.string.utf16) == h.doc.buffer.units)
}

extension PreviewSuites {
    @MainActor @Suite("Typing in the rendered pane", .serialized)
    struct RenderedWebTests {
        @Test("Engine scenarios pass through real keys and a fresh-render DOM comparison")
        func leafScenarios() async throws {
            let url = fixturesFolder.deletingLastPathComponent().appendingPathComponent("RenderedLeafScenarios.json")
            let scenarios = try JSONDecoder().decode([LeafScenario].self, from: Data(contentsOf: url))
            try #require(!scenarios.isEmpty)
            for s in scenarios {
                let before = unpack(s.before), after = unpack(s.after)
                let h = try PreviewHarness(text: before.text, windowClass: RenderedKeyWindow.self)
                defer { h.close() }
                try await beginEditing(h, at: before.selection)
                let original = h.doc.buffer.serialized(), v = h.doc.buffer.version
                switch s.inputType {
                case "insertText", "insertReplacementText": key(h, try #require(s.data))
                case "deleteContentBackward": key(h, "\u{7f}", code: 51)
                case "deleteContentForward": key(h, "\u{f728}", code: 117)
                default: throw HarnessFailure(description: "missing real key for \(s.inputType)")
                }
                try await waitForAck(h, 1)
                #expect(h.doc.buffer.version == v + 1, "\(s.before)")
                #expect(h.doc.buffer.units == Array(after.text.utf16), "\(s.before)")
                #expect(try await h.js("return marklight.selection()") as? [Int] == after.selection, "\(s.before)")
                try await checkFresh(h)
                key(h, "z", code: 6, flags: .command)
                try await waitForAck(h, 2)
                #expect(h.doc.buffer.serialized() == original, "\(s.before)")
                try await checkFresh(h)
            }
        }

        @Test("Browser word and line deletion uses WebKit's real target range")
        func keyboardDeletes() async throws {
            for (flags, before, after) in [(NSEvent.ModifierFlags.option, "abc xyz‸ q", "abc ‸ q"), (.command, "abc xyz‸ q", "‸ q")] {
                let h = try PreviewHarness(text: unpack(before).text, windowClass: RenderedKeyWindow.self)
                defer { h.close() }
                try await beginEditing(h, at: unpack(before).selection)
                key(h, "\u{7f}", code: 51, flags: flags)
                try await waitForAck(h, 1)
                #expect(h.doc.buffer.text == unpack(after).text, "\(before)")
                try await checkFresh(h)
            }
        }

        @Test("Deleting the last letter leaves a reachable caret and retyping fills it")
        func lastLetter() async throws {
            for marked in ["a‸", "top\n\na‸\n\nend", "- a‸\n", "> a‸\n", "# a‸\n"] {
                let (before, at) = unpack(marked)
                let h = try PreviewHarness(text: before, windowClass: RenderedKeyWindow.self)
                defer { h.close() }
                try await beginEditing(h, at: at)
                key(h, "\u{7f}", code: 51)
                try await waitForAck(h, 1)
                #expect(h.doc.buffer.units == Array(before.replacingOccurrences(of: "a", with: "").utf16))
                #expect(try await h.js("return !!document.querySelector('[data-caret] > br')") as? Bool == true)
                key(h, "z")
                try await waitForAck(h, 2)
                #expect(h.doc.buffer.units == Array(before.replacingOccurrences(of: "a", with: "z").utf16))
                try await checkFresh(h)
            }
        }

        @Test("Refused keys and clipboard/drop events beep once and preserve the DOM")
        func refusals() async throws {
            let before = "one\n\ntwo"
            let h = try PreviewHarness(text: before, windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            var beeps = 0
            h.pane.beep = { beeps += 1 }
            try await beginEditing(h, at: [5, 5])
            for i in 0..<7 {
                switch i {
                case 0: key(h, "\r", code: 36)
                case 1: key(h, "\u{7f}", code: 51) // second block start
                case 2: key(h, "b", code: 11, flags: .command)
                case 3, 4:
                    let name = i == 3 ? "paste" : "drop"
                    _ = try await h.js("document.querySelector('#doc').dispatchEvent(new Event(name, {bubbles:true, cancelable:true}))", ["name": name])
                case 5:
                    _ = try await h.js("marklight.select(1, 6)")
                    key(h, "\u{7f}", code: 51)
                default:
                    _ = try await h.js("""
                    marklight.select(1, 6);
                    document.querySelector('#doc').dispatchEvent(new InputEvent('beforeinput', {inputType:'deleteByCut', bubbles:true, cancelable:true}))
                    """)
                }
                try await waitForAck(h, i + 1)
                #expect(beeps == i + 1)
                #expect(h.doc.buffer.units == Array(before.utf16))
                #expect(!h.doc.buffer.canUndo)
                try await checkFresh(h)
            }
        }

        @Test("Swift refuses forged offsets in emoji, read-only blocks, raw HTML and outside the buffer")
        func untrustedInput() async throws {
            let text = "a🚀b\n\n<div contenteditable=true>raw</div>\n\n```\ncode\n```\n\n| cell |\n|------|"
            let h = try PreviewHarness(text: text, windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            var beeps = 0
            h.pane.beep = { beeps += 1 }
            try await beginEditing(h, at: [0, 0])
            #expect(try await h.js("return [...document.querySelectorAll('[data-raw], [data-raw] *, pre, table')].every(e => !e.isContentEditable)") as? Bool == true)
            let offsets = [2, (text as NSString).range(of: "raw").location, (text as NSString).range(of: "code").location,
                           (text as NSString).range(of: "cell").location, text.utf16.count + 1]
            for (index, offset) in offsets.enumerated() {
                _ = try await h.js("""
                window.webkit.messageHandlers.marklight.postMessage({type:'input', inputType:'insertText', v, start:at, end:at,
                    target:null, targetV:v, data:'x', composed:false, range:null})
                """, ["at": offset, "v": h.doc.buffer.version])
                #expect(await pump(until: { beeps == index + 1 }))
                #expect(h.doc.buffer.units == Array(text.utf16))
                try await checkFresh(h)
            }
        }

        @Test("Marked text commits once through NSTextInputClient in every editable place")
        func compositionCommit() async throws {
            for marked in ["你‸世界", "a⟦bc⟧d", "# a‸b\r\n", "- a‸b\n- c", "> a‸b", "__a‸b__", "[a‸b](/u)", "`a‸b`"] {
                let (text, selected) = unpack(marked)
                let h = try PreviewHarness(text: text, windowClass: RenderedKeyWindow.self)
                defer { h.close() }
                try await beginEditing(h, at: selected)
                let client = try #require(h.webView as Any as? NSTextInputClient)
                let notFound = NSRange(location: NSNotFound, length: 0)
                let v = h.doc.buffer.version
                for input in ["k", "かんじ", "漢字"] {
                    client.setMarkedText(input, selectedRange: NSRange(location: input.utf16.count, length: 0), replacementRange: notFound)
                    await pump(for: 0.04)
                    #expect(h.doc.buffer.version == v, "buffer changed during \(input) in \(marked)")
                }
                client.insertText("漢字", replacementRange: notFound)
                try await waitForAck(h, 1)
                var expected = Array(text.utf16)
                expected.replaceSubrange(selected[0]..<selected[1], with: "漢字".utf16)
                #expect(h.doc.buffer.units == expected, "\(marked)")
                #expect(h.doc.buffer.version == v + 1)
                try await checkFresh(h)
                key(h, "z", code: 6, flags: .command)
                try await waitForAck(h, 2)
                #expect(h.doc.buffer.units == Array(text.utf16))
                try await checkFresh(h)
            }
        }

        @Test("Composition survives a source patch and cancel restores a selection spanning two blocks")
        func compositionWithRemoteEditAndCancel() async throws {
            let h = try PreviewHarness(text: "top\n\nabc\n\ndef", windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await beginEditing(h, at: [6, 6])
            let client = try #require(h.webView as Any as? NSTextInputClient)
            let missing = NSRange(location: NSNotFound, length: 0)
            client.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: missing)
            await pump(for: 0.05)
            h.textView.textStorage?.replaceCharacters(in: NSRange(location: 5, length: 0), with: "QQ")
            try await h.settle()
            #expect(h.doc.buffer.text == "top\n\nQQabc\n\ndef")
            #expect(client.hasMarkedText())
            client.insertText("你", replacementRange: missing)
            try await waitForAck(h, 1)
            #expect(h.doc.buffer.text == "top\n\nQQa你bc\n\ndef")
            try await checkFresh(h)

            _ = try await h.js("marklight.select(8, 14)")
            let before = h.doc.buffer.units, version = h.doc.buffer.version
            client.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: missing)
            await pump(for: 0.05)
            client.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: missing)
            client.unmarkText()
            await pump(for: 0.1)
            #expect(h.doc.buffer.version == version)
            #expect(h.doc.buffer.units == before)
            #expect(try await h.js("return marklight.selection()") as? [Int] == [8, 14])
            try await checkFresh(h)
        }

        @Test("A typing burst queues a move behind the key that precedes it")
        func orderedMovement() async throws {
            let h = try PreviewHarness(text: "ab", windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await beginEditing(h, at: [1, 1])
            _ = try await h.js("""
            const done = marklight.done;
            marklight.done = () => setTimeout(done, 80);
            """)
            key(h, "x")
            key(h, "\u{f702}", code: 123)
            key(h, "y")
            try await waitForAck(h, 2)
            #expect(h.doc.buffer.text == "ayxb")
            try await checkFresh(h)
        }

        @Test("An edit in the other pane preserves the caret node and the next key lands at it")
        func remoteCaret() async throws {
            let text = (0..<160).map { "line \($0) with words\n\n" }.joined()
            let h = try PreviewHarness(text: text, size: NSSize(width: 900, height: 500), windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            let at = (text as NSString).range(of: "line 80 with").location + 5
            try await beginEditing(h, at: [at, at])
            _ = try await h.js("""
            window.watched = getSelection().focusNode;
            window.offsetBefore = getSelection().focusOffset;
            watched.parentElement.scrollIntoView({block:'center'});
            window.topBefore = watched.parentElement.getBoundingClientRect().top;
            """)
            h.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "prefix\n\n")
            try await h.settle()
            #expect(try await h.js("""
            return getSelection().focusNode === watched && getSelection().focusOffset === offsetBefore &&
                   Math.abs(watched.parentElement.getBoundingClientRect().top - topBefore) < 1.5
            """) as? Bool == true)
            key(h, "X")
            try await waitForAck(h, 1)
            #expect(h.doc.buffer.text.contains("line X80 with"))
            try await checkFresh(h)
        }

        @Test("Typing then deleting saves the original BOM and CRLF through NSDocument")
        func editDeleteSave() async throws {
            let folder = try makeTemporaryFolder(), bytes = Data([0xef, 0xbb, 0xbf]) + Data("a🚀b\r\n".utf8)
            let url = folder.appendingPathComponent("save.md")
            try bytes.write(to: url)
            let h = try PreviewHarness(url: url, windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await beginEditing(h, at: [1, 1])
            key(h, "x")
            try await waitForAck(h, 1)
            #expect(h.doc.buffer.isDirty)
            try await checkFresh(h)
            key(h, "\u{7f}", code: 51)
            try await waitForAck(h, 2)
            #expect(!h.doc.buffer.isDirty)
            try await checkFresh(h)
            var saved: Result<Void, Error>?
            h.doc.save(to: url, ofType: MarkdownDocument.markdownType, for: .saveOperation) { error in
                saved = error.map { .failure($0) } ?? .success(())
            }
            try #require(await pump(until: { saved != nil }))
            try saved?.get()
            #expect(try Data(contentsOf: url) == bytes)
        }
    }
}
