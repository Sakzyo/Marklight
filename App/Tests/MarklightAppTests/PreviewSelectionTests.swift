import AppKit
import Foundation
import MarklightCore
import Testing
@testable import MarklightApp

private let paragraphs = (0..<200).map { "Paragraph number \($0) with some words.\n\n" }.joined()

/// Whether the paragraph with this number is on screen.
private let isShowing = """
const p = [...document.querySelectorAll('#doc p')].find(p => p.textContent.startsWith(`Paragraph number ${n} `));
const box = p.getBoundingClientRect();
return box.bottom > 0 && box.top < innerHeight;
"""

@MainActor private func showing(_ h: PreviewHarness, _ n: Int) async throws -> Bool {
    try await h.js(isShowing, ["n": n]) as? Bool ?? false
}

@MainActor private func offset(of text: String, in h: PreviewHarness) -> Int {
    (h.doc.buffer.text as NSString).range(of: text).location
}

/// Counts the calls that reach the page, which a scroll position can't show.
private let countReveals = """
const reveal = marklight.reveal;
window._reveals = 0;
marklight.reveal = offset => { window._reveals++; reveal(offset); };
"""

/// Selects a DOM range and reports it, as a finished mouse drag would.
private let selectInRun = """
const run = document.querySelectorAll('#doc [data-run]:not([data-atomic])')[index];
const node = run.firstChild;
getSelection().setBaseAndExtent(node, start, node, end);
document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
return node.nodeValue.slice(start, end);
"""

extension PreviewSuites {
    @MainActor @Suite("Selection sync and anchors")
    struct PreviewSelectionTests {
        // MARK: - Source to preview

        @Test("Moving the source caret scrolls the preview to the matching block")
        func caretScrollsPreview() async throws {
            let h = try PreviewHarness(text: paragraphs, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            #expect(try await showing(h, 150) == false)
            h.textView.setSelectedRange(NSRange(location: offset(of: "Paragraph number 150 ", in: h), length: 0))
            await pump(for: 0.2)
            #expect(try await showing(h, 150))
        }

        @Test("A block already showing doesn't scroll")
        func visibleBlockStays() async throws {
            let h = try PreviewHarness(text: paragraphs, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            _ = try await h.js("window.scrollTo(0, 30)")
            h.textView.setSelectedRange(NSRange(location: offset(of: "Paragraph number 3 ", in: h), length: 0))
            await pump(for: 0.2)
            let y = try await h.js("return scrollY") as? Double
            #expect(y == 30)
        }

        @Test("In a long list, the preview scrolls to the item, not the top of the list")
        func listItem() async throws {
            let list = (0..<400).map { "- item \($0)\n" }.joined()
            let h = try PreviewHarness(text: list, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            h.textView.setSelectedRange(NSRange(location: offset(of: "item 300\n", in: h), length: 0))
            await pump(for: 0.2)
            let shown = try await h.js("""
            const li = [...document.querySelectorAll('li')].find(l => l.textContent === 'item 300');
            const box = li.getBoundingClientRect();
            return box.bottom > 0 && box.top < innerHeight;
            """) as? Bool
            #expect(shown == true)
        }

        @Test("Typing doesn't scroll the preview, even with the caret off screen")
        func typingHoldsStill() async throws {
            let h = try PreviewHarness(text: paragraphs, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            _ = try await h.js(countReveals)
            h.textView.setSelectedRange(NSRange(location: 5, length: 0))
            var reveals = 0
            // A reveal arriving after the scroll below would undo it, so wait for this one.
            for _ in 0..<200 where reveals == 0 {
                await pump(for: 0.01)
                reveals = try await h.js("return window._reveals") as? Int ?? 0
            }
            #expect(reveals == 1)
            _ = try await h.js("window.scrollTo(0, 3000)")
            for ch in "typed" { h.textView.insertText(String(ch), replacementRange: h.textView.selectedRange()) }
            try await h.settle()
            await pump(for: 0.15)
            let y = try await h.js("return scrollY") as? Double
            #expect(y == 3000)
            let after = try await h.js("return window._reveals") as? Int
            #expect(after == 1, "typing asked the preview to scroll")
        }

        @Test("A reveal waits for the page to have the text it refers to")
        func revealWaitsForPatch() async throws {
            let h = try PreviewHarness(text: "start\n", size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            try h.doc.buffer.apply(Patch(range: 6..<6, replacement: Array(paragraphs.utf16), origin: .command))
            #expect(!h.pane.updater.isCurrent, "the page has to be behind for this to mean anything")
            h.pane.reveal(offset(of: "Paragraph number 150 ", in: h))
            try await h.settle()
            await pump(for: 0.1)
            #expect(try await showing(h, 150))
        }

        @Test("A caret move still scrolls after an edit that left the caret alone")
        func moveAfterUnrelatedEdit() async throws {
            let h = try PreviewHarness(text: paragraphs, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            let end = h.doc.buffer.units.count
            try h.doc.buffer.apply(Patch(range: end..<end, replacement: Array("New text at the end.\n".utf16), origin: .command))
            try await h.settle()
            h.textView.setSelectedRange(NSRange(location: offset(of: "Paragraph number 150 ", in: h), length: 0))
            await pump(for: 0.2)
            #expect(try await showing(h, 150))
        }

        @Test("Undo shows what it changed")
        func undoReveals() async throws {
            let h = try PreviewHarness(text: paragraphs, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            let at = offset(of: "Paragraph number 150 ", in: h)
            h.textView.setSelectedRange(NSRange(location: at, length: 0))
            h.textView.insertText("x", replacementRange: h.textView.selectedRange())
            await pump(for: 0.15)
            try await h.settle()
            _ = try await h.js("window.scrollTo(0, 0)")
            h.textView.setSelectedRange(NSRange(location: 0, length: 0))
            await pump(for: 0.15)
            _ = try await h.js("window.scrollTo(0, 0)")
            h.controller.editor.undo()
            try await h.settle()
            await pump(for: 0.2)
            #expect(try await showing(h, 150))
        }

        // MARK: - Preview to source

        @Test("Clicking in the preview moves the source caret there, with no echo")
        func clickMovesCaret() async throws {
            let h = try PreviewHarness(text: paragraphs, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            let point = try await h.center(of: "#doc p:nth-of-type(1) span")
            _ = try await h.js("window.scrollTo(0, 0)")
            _ = try await h.js(countReveals)
            await pump(for: 0.05)
            await h.click(x: point.x, y: point.y)
            #expect(await pump(until: { h.textView.selectedRange().location < 40 }, timeout: 2), "caret at \(h.textView.selectedRange())")
            await pump(for: 0.2)
            let reveals = try await h.js("return window._reveals") as? Int
            #expect(reveals == 0, "the source caret's move came back to the preview")
        }

        @Test("Dragging in the preview selects the same text in the source")
        func dragSelects() async throws {
            let h = try PreviewHarness(text: "First paragraph of words.\n\nSecond paragraph of words.\n")
            defer { h.close() }
            try await h.settle()
            let box: [Double] = try await h.json("""
            const [a, b] = document.querySelectorAll('#doc p');
            const x = a.firstChild.getClientRects()[0], y = b.firstChild.getClientRects()[0];
            return [x.left + 30, x.top + x.height / 2, y.left + 60, y.top + y.height / 2];
            """)
            await h.click(x: box[0], y: box[1], to: (box[2], box[3]))
            #expect(await pump(until: { h.textView.selectedRange().length > 0 }, timeout: 2), "selection \(h.textView.selectedRange())")
            let selected = (h.doc.buffer.text as NSString).substring(with: h.textView.selectedRange())
            let shown = try await h.js("return getSelection().toString()") as? String
            #expect(selected.contains("\n\n"), "\(selected)")
            #expect(selected.replacingOccurrences(of: "\n", with: "") == shown?.replacingOccurrences(of: "\n", with: ""), "\(selected) vs \(shown ?? "")")
        }

        @Test("A selection maps to the same text, across emoji, CJK, and marks")
        func multibyteMapping() async throws {
            let h = try PreviewHarness(text: "😀 **漢字 bold** after `code` 😀 end\n\n- item 👩‍👩‍👧 x\n")
            defer { h.close() }
            try await h.settle()
            var seen: [Range<Int>] = []
            h.pane.selectionChanged = { seen.append($0) }
            let count = try await h.js("return document.querySelectorAll('#doc [data-run]:not([data-atomic])').length") as? Int ?? 0
            #expect(count >= 5)
            for index in 0..<count {
                let length = try await h.js("return document.querySelectorAll('#doc [data-run]:not([data-atomic])')[index].firstChild.length", ["index": index]) as? Int ?? 0
                guard length >= 2 else { continue }
                let text = try await h.js(selectInRun, ["index": index, "start": 0, "end": length]) as? String ?? ""
                #expect(await pump(until: { !seen.isEmpty }, timeout: 2))
                let last = seen.popLast()
                let range = try #require(last)
                let source = String(decoding: h.doc.buffer.units[range], as: UTF16.self)
                #expect(source == text, "run \(index)")
            }
        }

        @Test("Every run in every fixture maps back to its own text", arguments: previewFixtureNames)
        func fixtureMapping(name: String) async throws {
            let h = try PreviewHarness(url: fixturesFolder.appendingPathComponent(name))
            defer { h.close() }
            try await h.settle()
            var seen: [Range<Int>] = []
            h.pane.selectionChanged = { seen.append($0) }
            let count = try await h.js("return document.querySelectorAll('#doc [data-run]:not([data-atomic])').length") as? Int ?? 0
            for index in stride(from: 0, to: count, by: max(1, count / 12)) {
                let length = try await h.js("return document.querySelectorAll('#doc [data-run]:not([data-atomic])')[index].firstChild.length", ["index": index]) as? Int ?? 0
                guard length >= 1 else { continue }
                let text = try await h.js(selectInRun, ["index": index, "start": 0, "end": length]) as? String ?? ""
                #expect(await pump(until: { !seen.isEmpty }, timeout: 2), "\(name), run \(index)")
                guard let range = seen.popLast() else { return }
                let source = h.doc.buffer.units[range].map { $0 == 0 ? 0xFFFD : $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 }
                #expect(source == Array(text.utf16), "\(name), run \(index)")
            }
        }

        @Test("Raw HTML can't steer the caret with forged offsets")
        func forgedSelection() async throws {
            let h = try PreviewHarness(text: "before\n\n<p data-src=\"0:1\" data-run>raw text</p>\n\nafter\n")
            defer { h.close() }
            try await h.settle()
            let point = try await h.center(of: "[data-raw] p")
            await h.click(x: point.x, y: point.y)
            let start = offset(of: "<p data-src", in: h)
            #expect(await pump(until: { h.textView.selectedRange().location == start }, timeout: 2), "caret at \(h.textView.selectedRange()), block at \(start)")
        }

        @Test("Clicking with the preview alone showing still moves the hidden caret")
        func previewOnlyClick() async throws {
            let h = try PreviewHarness(text: "one\n\ntwo words here\n", layout: .preview)
            defer { h.close() }
            try await h.settle()
            let point = try await h.center(of: "#doc p:nth-of-type(1) span", text: "two words here")
            await h.click(x: point.x, y: point.y)
            #expect(await pump(until: { h.textView.selectedRange().location >= 5 && h.textView.selectedRange().location < 19 }, timeout: 2))
        }

        @Test("Offsets from an older page are carried to the current text")
        func staleOffsets() async throws {
            let h = try PreviewHarness(text: "one two three\n")
            defer { h.close() }
            try await h.settle()
            let old = h.doc.buffer.version
            var seen: [Range<Int>] = []
            h.pane.selectionChanged = { seen.append($0) }
            try h.doc.buffer.apply(Patch(range: 0..<0, replacement: Array("xxx".utf16), origin: .command))
            _ = try await h.js("window.webkit.messageHandlers.marklight.postMessage({ type: 'selection', v, start: 4, end: 7 })", ["v": old])
            #expect(await pump(until: { !seen.isEmpty }, timeout: 2))
            #expect(seen == [7..<10])
            #expect(String(decoding: h.doc.buffer.units[7..<10], as: UTF16.self) == "two")
        }

        @Test("Offsets too old to carry are dropped")
        func tooStale() async throws {
            let h = try PreviewHarness(text: "text\n")
            defer { h.close() }
            try await h.settle()
            let old = h.doc.buffer.version
            var seen: [Range<Int>] = []
            h.pane.selectionChanged = { seen.append($0) }
            for _ in 0..<600 { try h.doc.buffer.apply(Patch(range: 0..<0, replacement: [0x78], origin: .command)) }
            _ = try await h.js("window.webkit.messageHandlers.marklight.postMessage({ type: 'selection', v, start: 1, end: 2 })", ["v": old])
            await pump(for: 0.2)
            #expect(seen.isEmpty)
            #expect(h.pane.rejectedMessages.isEmpty, "it's a valid message, just out of date")
        }

        @Test("A patch that replaces selected nodes reports nothing")
        func patchIsSilent() async throws {
            let h = try PreviewHarness(text: "one\n\ntwo\n")
            defer { h.close() }
            try await h.settle()
            var seen: [Range<Int>] = []
            h.pane.selectionChanged = { seen.append($0) }
            _ = try await h.js("getSelection().selectAllChildren(document.querySelector('#doc p'))")
            try h.doc.buffer.apply(Patch(range: 0..<5, replacement: [], origin: .command))
            try await h.settle()
            await pump(for: 0.2)
            #expect(seen.isEmpty, "\(seen)")
        }

        // MARK: - Anchors

        private let anchors = (["# Intro\n\n[to second](#same-1) [to first](#same) [to raw](#named) [punctuated](#whats-new-in-v2) [case](#INTRO) [nowhere](#missing) [same file](doc.md#same-1)\n\n"]
            + (0..<60).map { "Paragraph \($0).\n\n" } + ["## Same\n\n"]
            + (0..<60).map { "Middle \($0).\n\n" } + ["## Same\n\n"]
            + (0..<60).map { "Later \($0).\n\n" } + ["<div><a name=\"named\"></a></div>\n\n## What's New in v2?\n\n"]
            + (0..<60).map { "Final \($0).\n\n" }).joined()

        @Test("Anchor links scroll to their target, and go nowhere else", arguments: [
            ("to first", "Same", 0), ("to second", "Same", 1), ("punctuated", "What's New in v2?", 0), ("same file", "Same", 1),
        ])
        func anchorLinks(link: String, heading: String, index: Int) async throws {
            let h = try PreviewHarness(text: anchors, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            var opened: [URL] = []
            h.pane.openExternal = { opened.append($0) }
            h.pane.openMarkdown = { opened.append($0) }
            try await h.settle()
            let start = h.webView.url
            let point = try await h.center(of: "a", text: link)
            await pump(for: 0.05)
            await h.click(x: point.x, y: point.y)
            await pump(for: 0.2)
            let top = try await h.js("""
            return [...document.querySelectorAll('h1, h2')].filter(e => e.textContent === heading)[index].getBoundingClientRect().top;
            """, ["heading": heading, "index": index]) as? Double ?? -1
            #expect(abs(top) < 2, "\(link): the heading is at \(top)")
            #expect(opened.isEmpty)
            #expect(h.webView.url == start)
        }

        @Test("A raw named anchor works, and a missing one does nothing")
        func otherAnchors() async throws {
            let h = try PreviewHarness(text: anchors, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            let point = try await h.center(of: "a", text: "to raw")
            await pump(for: 0.05)
            await h.click(x: point.x, y: point.y)
            await pump(for: 0.2)
            let y = try await h.js("return scrollY") as? Double ?? 0
            #expect(y > 1000)

            let missing = try await h.center(of: "a", text: "nowhere")
            await pump(for: 0.05)
            let before = try await h.js("return scrollY") as? Double
            await h.click(x: missing.x, y: missing.y)
            await pump(for: 0.2)
            let after = try await h.js("return scrollY") as? Double
            #expect(before == after)
        }
    }
}
