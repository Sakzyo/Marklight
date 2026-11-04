import AppKit
import Foundation
import MarklightCore
import Testing
import WebKit
@testable import MarklightApp

/// WebKit ignores ordinary keys in the test process's inactive window.
final class RenderedKeyWindow: NSWindow {
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

@MainActor func key(_ h: PreviewHarness, _ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
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

/// The test process is never the active app. Give the real Edit menu the
/// responder Cocoa would target in the app's key window.
@MainActor private func sourceUndoKey(_ h: PreviewHarness) throws {
    h.window.makeFirstResponder(h.textView)
    let menu = try #require(MainMenu.make().items.compactMap(\.submenu).first { $0.title == "Edit" })
    let undo = try #require(menu.items.first { $0.action == #selector(SourceTextView.undo(_:)) })
    undo.target = h.textView
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
    try #require(menu.performKeyEquivalent(with: event))
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
@MainActor private func checkFresh(_ h: PreviewHarness, pending: Int? = nil) async throws {
    let live = try await h.dom()
    let selection = try await h.js("return marklight.selection()") as? [Int]
    let full = HTMLRenderer.render(IncrementalDocument(units: h.doc.buffer.units), pending: pending)
    let list = full.blocks.map { ["html": $0.html, "base": $0.base] as [String: Any] }
    _ = try await h.js("marklight.load(list, v, start, end)", [
        "list": list, "v": h.doc.buffer.version, "start": selection?.first as Any? ?? NSNull(), "end": selection?.last as Any? ?? NSNull(),
    ])
    let fresh = try await h.dom()
    if !fresh.utf8.elementsEqual(live.utf8) {
        Issue.record("DOM for \(h.doc.buffer.text.prefix(60).debugDescription) at version \(h.doc.buffer.version) differs. Live \(live.prefix(650)); fresh \(fresh.prefix(650))")
    }
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
            for (flags, before, after) in [(NSEvent.ModifierFlags.option, "abc xyz‸ q", "abc ‸ q"), (.command, "abc xy‸z q", "‸z q")] {
                let h = try PreviewHarness(text: unpack(before).text, windowClass: RenderedKeyWindow.self)
                defer { h.close() }
                try await beginEditing(h, at: unpack(before).selection)
                key(h, "\u{7f}", code: 51, flags: flags)
                try await waitForAck(h, 1)
                #expect(h.doc.buffer.text == unpack(after).text, "\(before)")
                try await checkFresh(h)
            }
        }

        @Test("Deleting to line start cannot discard an untouched leading space")
        func deleteLeavingWhitespace() async throws {
            let h = try PreviewHarness(text: "abc xyz q", windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            var beeps = 0
            h.pane.beep = { beeps += 1 }
            try await beginEditing(h, at: [7, 7])
            key(h, "\u{7f}", code: 51, flags: .command)
            try await waitForAck(h, 1)
            // CommonMark would consume the space as indentation, changing the
            // surviving atoms. Refuse this edit before touching the source.
            #expect(beeps == 1)
            #expect(h.doc.buffer.units == Array("abc xyz q".utf16))
            try await checkFresh(h)
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
                try await checkFresh(h, pending: at[0] - 1)
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
            // A valid caret cannot legitimize a forged target that splits the
            // rocket. Treating a failed target lookup as nil would insert at 0.
            _ = try await h.js("""
            window.webkit.messageHandlers.marklight.postMessage({type:'input', inputType:'insertReplacementText', v,
                start:0, end:0, target:[2,2], targetV:v, data:'forged', composed:false, range:null})
            """, ["v": h.doc.buffer.version])
            #expect(await pump(until: { beeps == offsets.count + 1 }, timeout: 1))
            #expect(h.doc.buffer.units == Array(text.utf16))
            try await checkFresh(h)
        }

        @Test("Backspace on focusable raw HTML cannot use an old editable caret")
        func rawFocus() async throws {
            let source = "editable text\n\n<div><a tabindex='0' style='-webkit-user-modify:read-write !important' href='https://example.com/'>raw</a></div>"
            let h = try PreviewHarness(text: source, windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            var beeps = 0
            h.pane.beep = { beeps += 1 }
            try await beginEditing(h, at: [4, 4])
            let protected = try await h.js("""
            const a = document.querySelector('[data-raw] a');
            a.focus();
            getSelection().removeAllRanges();
            return document.activeElement === a && !a.isContentEditable && getComputedStyle(a).webkitUserModify === 'read-only';
            """) as? Bool
            #expect(protected == true)
            key(h, "\u{7f}", code: 51)
            try await waitForAck(h, 1)
            #expect(beeps == 1)
            #expect(h.doc.buffer.units == Array(source.utf16))
            try await checkFresh(h)
        }

        @Test("A raw image map opens only on Cmd-click")
        func imageMapLink() async throws {
            let folder = try makeTemporaryFolder()
            let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
            try image.write(to: folder.appendingPathComponent("dot.png"))
            let file = folder.appendingPathComponent("map.md")
            try Data("""
            <div><img src="dot.png" width="80" height="60" usemap="#targets">
            <map name="targets"><area shape="default" href="https://example.com/map"></map></div>
            """.utf8).write(to: file)
            let h = try PreviewHarness(url: file, windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            var opened: [String] = []
            h.pane.openExternal = { opened.append($0.absoluteString) }
            try await h.settle()
            let point = try await h.center(of: "[data-raw] img")
            await h.click(x: point.x, y: point.y)
            await pump(for: 0.12)
            #expect(opened.isEmpty)
            await h.click(x: point.x, y: point.y, modifiers: .command)
            #expect(await pump(until: { opened.count == 1 }, timeout: 2))
            #expect(opened == ["https://example.com/map"])
        }

        @Test("A full reload discards keys queued against an old document and ignores its late composition end")
        func fullReload() async throws {
            let h = try PreviewHarness(text: "old text", windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await beginEditing(h, at: [4, 4])
            _ = try await h.js("""
            window.acknowledge = marklight.done;
            marklight.done = () => { window.hasReply = true; };
            """)
            key(h, "X")
            #expect(await pump(until: { h.doc.buffer.text == "old Xtext" }))
            try await h.settle()
            key(h, "Y")
            await pump(for: 0.04)
            let reset = "different document"
            h.doc.buffer.reload(contentsOf: Data(reset.utf8))
            h.pane.updater.pageReady()
            try await h.settle()
            #expect(try await h.js("return window.hasReply") as? Bool == true)
            _ = try await h.js("marklight.done = acknowledge; marklight.done()")
            await pump(for: 0.12)
            #expect(h.doc.buffer.text == reset)
            try await checkFresh(h)

            _ = try await h.js("document.querySelector('#doc').focus(); marklight.select(3, 3)")
            let client = try #require(h.webView as Any as? NSTextInputClient)
            client.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            await pump(for: 0.05)
            let final = "newer contents"
            h.doc.buffer.reload(contentsOf: Data(final.utf8))
            h.pane.updater.pageReady()
            try await h.settle()
            _ = try await h.js("document.querySelector('#doc').dispatchEvent(new CompositionEvent('compositionend', {bubbles:true, data:'你'}))")
            await pump(for: 0.12)
            #expect(h.doc.buffer.text == final)
            try await checkFresh(h)
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
            _ = try await h.js("""
            window.compositionEnds = 0;
            document.addEventListener('compositionend', () => compositionEnds++);
            """)
            client.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: missing)
            await pump(for: 0.05)
            #expect(try await h.js("""
            window.markedNode = getSelection().focusNode;
            window.markedOffset = getSelection().focusOffset;
            return document.querySelector('#doc').textContent.includes('anibc') && compositionEnds === 0;
            """) as? Bool == true)
            h.textView.textStorage?.replaceCharacters(in: NSRange(location: 5, length: 0), with: "QQ")
            try await h.settle()
            #expect(h.doc.buffer.text == "top\n\nQQabc\n\ndef")
            #expect(try await h.js("""
            return markedNode.isConnected && getSelection().focusNode === markedNode && getSelection().focusOffset === markedOffset &&
                   document.querySelector('#doc').textContent.includes('anibc') && compositionEnds === 0;
            """) as? Bool == true)
            client.insertText("你", replacementRange: missing)
            try await waitForAck(h, 1)
            #expect(h.doc.buffer.text == "top\n\nQQa你bc\n\ndef")
            #expect(try await h.js("return window.compositionEnds") as? Int == 1)
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

        @Test("A composition cannot overwrite an intervening source edit in its saved range")
        func composingRangeConflict() async throws {
            let edits: [(NSRange, String, String, Bool)] = [
                (NSRange(location: 2, length: 0), "X", "abXcd", false),
                (NSRange(location: 1, length: 2), "QQ", "aQQd", false),
                (NSRange(location: 3, length: 0), "X", "aZXd", true),
                (NSRange(location: 1, length: 0), "X", "aXZd", true),
            ]
            for (remote, replacement, expected, accepted) in edits {
                let h = try PreviewHarness(text: "abcd", windowClass: RenderedKeyWindow.self)
                defer { h.close() }
                var beeps = 0
                h.pane.beep = { beeps += 1 }
                try await beginEditing(h, at: [1, 3])
                let client = try #require(h.webView as Any as? NSTextInputClient)
                let missing = NSRange(location: NSNotFound, length: 0)
                client.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: missing)
                await pump(for: 0.04)
                #expect(h.doc.buffer.text == "abcd")
                h.textView.textStorage?.replaceCharacters(in: remote, with: replacement)
                try await h.settle()
                let version = h.doc.buffer.version
                client.insertText("Z", replacementRange: missing)
                try await waitForAck(h, 1)
                #expect(h.doc.buffer.text == expected, "source edit \(remote)")
                #expect(h.doc.buffer.version == version + (accepted ? 1 : 0))
                #expect(beeps == (accepted ? 0 : 1))
                try await checkFresh(h)
            }
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

        @Test("Home, End and Page moves queued between real keys replay before the next key")
        func longMoves() async throws {
            let text = (0..<120).map { "line \($0) here\n\n" }.joined()
            let at = (text as NSString).range(of: "line 60 here").location + 3
            for (chars, code, name) in [("\u{f729}", UInt16(115), "Home"), ("\u{f72b}", 119, "End"),
                                         ("\u{f72c}", 116, "PageUp"), ("\u{f72d}", 121, "PageDown")] {
                let h = try PreviewHarness(text: text, size: NSSize(width: 900, height: 450), windowClass: RenderedKeyWindow.self)
                defer { h.close() }
                try await beginEditing(h, at: [at, at])
                _ = try await h.js("""
                getSelection().focusNode.parentElement.scrollIntoView({block:'center'});
                const done = marklight.done;
                marklight.done = () => setTimeout(done, 75);
                """)
                key(h, "X")
                key(h, chars, code: code)
                key(h, "Y")
                try await waitForAck(h, 2)
                let written = h.doc.buffer.text as NSString
                let x = written.range(of: "X").location, y = written.range(of: "Y").location
                try #require(x != NSNotFound && y != NSNotFound)
                switch name {
                case "Home": #expect(y == 0)
                case "End": #expect(y == written.length - 3)
                case "PageUp": #expect(y < x - 20 && y > 0)
                default: #expect(y > x + 20 && y < written.length - 3)
                }
                try await checkFresh(h)
            }
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

        @Test("Refocusing the preview restores its caret across a source edit above it")
        func focusRoundTrip() async throws {
            let h = try PreviewHarness(text: "top\n\na🚀bc", windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await beginEditing(h, at: [8, 8])
            h.window.makeFirstResponder(h.textView)
            h.textView.setSelectedRange(NSRange(location: 0, length: 0))
            key(h, "P")
            #expect(await pump(until: { h.doc.buffer.text == "Ptop\n\na🚀bc" }))
            try await h.settle()
            // Tab/focus returns to the web view; there is no click or explicit
            // marklight.select to put its selection back for it.
            h.window.makeFirstResponder(h.webView)
            key(h, "Y")
            try await waitForAck(h, 1)
            #expect(h.doc.buffer.text == "Ptop\n\na🚀Ybc")
            try await checkFresh(h)
        }

        @Test("The pane receiving Cmd-Z gets the selection in a mixed editing session")
        func mixedUndo() async throws {
            let h = try PreviewHarness(text: "ab\r\n", windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await beginEditing(h, at: [1, 1])
            key(h, "X")
            try await waitForAck(h, 1)
            try await checkFresh(h)
            h.window.makeFirstResponder(h.textView)
            h.textView.setSelectedRange(NSRange(location: 0, length: 0))
            var sourcePatch: Patch?
            let token = h.doc.buffer.addObserver { if $0.origin == .source { sourcePatch = $0 } }
            defer { h.doc.buffer.removeObserver(token) }
            key(h, "Y")
            #expect(await pump(until: { h.doc.buffer.text == "YaXb\r\n" }))
            try await h.settle()
            h.window.makeFirstResponder(h.webView)
            _ = try await h.js("document.querySelector('#doc').focus(); marklight.select(3, 3)")
            key(h, "z", code: 6, flags: .command)
            try await waitForAck(h, 2)
            #expect(h.doc.buffer.text == "aXb\r\n")
            #expect(try await h.js("return marklight.selection()") as? [Int] == [0, 0])
            try await checkFresh(h)
            key(h, "Z", code: 6, flags: [.command, .shift])
            try await waitForAck(h, 3)
            #expect(h.doc.buffer.text == "YaXb\r\n")
            let caret = try await h.js("return marklight.selection()") as? [Int]
            #expect(caret == [1, 1], "after redoing the source Y at 0, source patch was \(String(describing: sourcePatch))")
            #expect(h.pane.updater.pending == nil)
            try await checkFresh(h)

            for expected in ["aXb\r\n", "ab\r\n"] {
                try sourceUndoKey(h)
                #expect(await pump(until: { h.doc.buffer.text == expected }))
                try await h.settle()
                try await checkFresh(h)
            }
            #expect(h.textView.selectedRange() == NSRange(location: 1, length: 0))
            #expect(h.doc.buffer.serialized() == Data("ab\r\n".utf8))
        }

        @Test("Both panes restore a real pending paragraph when undoing and redoing")
        func pendingHistory() async throws {
            let h = try PreviewHarness(text: "top\n\na\n\nend", windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await beginEditing(h, at: [6, 6])
            key(h, "\u{7f}", code: 51)
            try await waitForAck(h, 1)
            #expect(h.pane.updater.pending == 5)
            try await checkFresh(h, pending: 5)
            key(h, "x")
            try await waitForAck(h, 2)
            #expect(h.doc.buffer.text == "top\n\nx\n\nend")
            try await checkFresh(h)
            try sourceUndoKey(h)
            try await h.settle()
            #expect(h.pane.updater.pending == 5)
            #expect(h.textView.selectedRange() == NSRange(location: 5, length: 0))
            try await checkFresh(h, pending: 5)
            h.window.makeFirstResponder(h.webView)
            _ = try await h.js("document.querySelector('#doc').focus(); marklight.select(5,5)")
            key(h, "y")
            try await waitForAck(h, 3)
            #expect(h.doc.buffer.text == "top\n\ny\n\nend")
            key(h, "z", code: 6, flags: .command)
            try await waitForAck(h, 4)
            #expect(try await h.js("return marklight.selection()") as? [Int] == [5, 5])
            try await checkFresh(h, pending: 5)
            key(h, "Z", code: 6, flags: [.command, .shift])
            try await waitForAck(h, 5)
            #expect(h.doc.buffer.text == "top\n\ny\n\nend")
            try await checkFresh(h)
            for pending in [5, nil] as [Int?] {
                try sourceUndoKey(h)
                try await h.settle()
                #expect(h.pane.updater.pending == pending)
                try await checkFresh(h, pending: pending)
            }
            #expect(h.doc.buffer.serialized() == Data("top\n\na\n\nend".utf8))
        }

        @Test("A rendered edit carries the source caret without scrolling its viewport")
        func sourceHoldsStill() async throws {
            let original = (0..<250).map { "Paragraph number \($0) has text here.\n\n" }.joined()
            let h = try PreviewHarness(text: original, size: NSSize(width: 1000, height: 450), windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            let at = (original as NSString).range(of: "Paragraph number 190").location + 4
            h.textView.setSelectedRange(NSRange(location: at, length: 0))
            h.textView.scrollRangeToVisible(h.textView.selectedRange())
            await pump(for: 0.1)
            try await beginEditing(h, at: [1, 1])
            let scroll = h.controller.editor.scrollView.contentView.bounds.origin
            #expect(scroll.y > 0)
            key(h, "x")
            try await waitForAck(h, 1)
            #expect(h.textView.selectedRange() == NSRange(location: at + 1, length: 0))
            #expect(abs(h.controller.editor.scrollView.contentView.bounds.origin.y - scroll.y) < 1)
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
