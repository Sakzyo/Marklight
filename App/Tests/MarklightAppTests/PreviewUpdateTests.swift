import AppKit
import CryptoKit
import Foundation
import MarklightCore
import Testing
@testable import MarklightApp

/// SplitMix64, so a failing run can be repeated.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private let insertions = [
    "x", " word", "\n", "\n\n", "# New heading\n\n", "- [ ] task\n- item\n", "| a | b |\n|---|:-:|\n| 1 |\n\n",
    "```swift\nlet a = 1\n```\n", "**bold** and `code` ", "<div onclick=\"x\">raw <b>html</b></div>\n\n",
    "> quote\n", "![image](a.png)", "[link](b.md)", "1. one\n2. two\n", "😀 漢字 ", "---\n", "&amp; \\* ",
]

/// One random edit, or nil if it landed inside a surrogate pair.
private func randomPatch(_ buffer: Buffer, _ rng: inout SeededGenerator) -> Patch? {
    let count = buffer.units.count
    let at = Int.random(in: 0...count, using: &rng)
    let patch: Patch
    if Bool.random(using: &rng), at < count {
        patch = Patch(range: at..<min(count, at + Int.random(in: 1...40, using: &rng)), replacement: [], origin: .command)
    } else {
        patch = Patch(range: at..<at, replacement: Array(insertions.randomElement(using: &rng)!.utf16), origin: .command)
    }
    let splits: (Int) -> Bool = { $0 > 0 && $0 < count && (0xDC00..<0xE000).contains(buffer.units[$0]) }
    return splits(patch.range.lowerBound) || splits(patch.range.upperBound) ? nil : patch
}

/// Tags every node, so a later check can tell which ones survived, and starts
/// recording every change to the DOM.
private let tagNodes = """
const root = document.getElementById('doc');
const walk = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
let n = 0;
while (walk.nextNode()) walk.currentNode._tag = ++n;
window._changes = new MutationObserver(() => {});
window._changes.observe(root, { subtree: true, childList: true, characterData: true, attributes: true });
return n;
"""

/// Outside block `skip`: nodes that are new, nodes checked, and DOM changes seen.
private let countChanges = """
const root = document.getElementById('doc');
const inSkipped = node => {
  let el = node.nodeType === 1 ? node : node.parentElement;
  while (el && el.parentElement !== root) el = el.parentElement;
  return el === root.children[skip];
};
let lost = 0, total = 0;
[...root.children].forEach((block, i) => {
  if (i === skip) return;
  const walk = document.createTreeWalker(block, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
  while (walk.nextNode()) { total++; if (walk.currentNode._tag === undefined) lost++; }
});
const changes = window._changes.takeRecords().filter(r => r.target !== root && !inSkipped(r.target)).length;
return [lost, total, changes];
"""

/// Remembers the text at the top of the viewport, and returns where it is. It's
/// the text that has to hold still: a reused node showing other text proves nothing.
private let watchTop = """
const el = [...document.querySelectorAll('#doc p, #doc li')].find(el => el.getBoundingClientRect().top > 0);
window._watched = el.textContent;
return el.getBoundingClientRect().top;
"""

private let watchedTop = """
const el = [...document.querySelectorAll('#doc p, #doc li')].find(el => el.textContent === window._watched);
return el ? el.getBoundingClientRect().top : null;
"""

/// Stops the page's scroll correction, as if anchoring had been removed.
private let removeAnchoring = "window.scrollBy = () => {}"

extension PreviewSuites {
    @MainActor @Suite("Preview updates")
    struct PreviewUpdateTests {
        // MARK: - The DOM follows the buffer

        @Test("After random edits, the live DOM equals a fresh render, node for node", arguments: previewFixtureNames)
        func liveEqualsFresh(name: String) async throws {
            let url = fixturesFolder.appendingPathComponent(name)
            let live = try PreviewHarness(url: url)
            defer { live.close() }
            let fresh = try PreviewHarness(url: url) // always replaced wholesale, so it can't drift
            defer { fresh.close() }
            try await live.settle()

            var rng = SeededGenerator(state: UInt64(truncatingIfNeeded: name.utf8.reduce(5381) { $0 &* 33 &+ Int($1) }))
            for round in 0..<6 {
                for _ in 0..<(round % 3 + 1) { // sometimes several edits in one update
                    guard let patch = randomPatch(live.doc.buffer, &rng) else { continue }
                    try live.doc.buffer.apply(patch)
                    try fresh.doc.buffer.apply(patch)
                }
                try await live.settle()
                try await fresh.freshRender()
                let a = try await live.dom(), b = try await fresh.dom()
                #expect(a == b, "\(name), round \(round)")
                guard a == b else { return }
            }
        }

        @Test("Typing in the source pane reaches the preview")
        func typing() async throws {
            let h = try PreviewHarness(text: "# Title\n\nBody\n")
            defer { h.close() }
            try await h.settle()
            h.textView.setSelectedRange(NSRange(location: 7, length: 0))
            for ch in " here" { h.textView.insertText(String(ch), replacementRange: h.textView.selectedRange()) }
            try await h.settle()
            let title = try await h.js("return document.querySelector('h1').textContent") as? String
            #expect(title == "Title here")
        }

        @Test("Undo, redo, and a reload from disk reach the preview")
        func history() async throws {
            let h = try PreviewHarness(text: "one\n\ntwo\n")
            defer { h.close() }
            try await h.settle()
            func text() async throws -> String { try await h.js("return document.getElementById('doc').textContent") as? String ?? "" }

            try h.doc.buffer.apply(Patch(range: 3..<3, replacement: Array(" more".utf16), origin: .command))
            try await h.settle()
            #expect(try await text() == "one moretwo")
            h.doc.buffer.undo()
            try await h.settle()
            #expect(try await text() == "onetwo")
            h.doc.buffer.redo()
            try await h.settle()
            #expect(try await text() == "one moretwo")
            h.doc.buffer.reload(contentsOf: Data("replaced\n".utf8))
            try await h.settle()
            #expect(try await text() == "replaced")
        }

        @Test("Emptying a document, and filling it again, both work")
        func empty() async throws {
            let h = try PreviewHarness(text: "text\n")
            defer { h.close() }
            try await h.settle()
            try h.doc.buffer.apply(Patch(range: 0..<5, replacement: [], origin: .command))
            try await h.settle()
            let none = try await h.js("return document.getElementById('doc').children.length") as? Int
            #expect(none == 0)
            try h.doc.buffer.apply(Patch(range: 0..<0, replacement: Array("# Back\n".utf16), origin: .command))
            try await h.settle()
            let back = try await h.js("return document.querySelectorAll('h1').length") as? Int
            #expect(back == 1)
        }

        @Test("A burst of edits is one update")
        func coalesces() async throws {
            let h = try PreviewHarness(text: "text\n")
            defer { h.close() }
            try await h.settle()
            var updates = 0
            let present = h.pane.updater.present
            h.pane.updater.present = { update, done in
                updates += 1
                present(update, done)
            }
            for i in 0..<300 {
                try h.doc.buffer.apply(Patch(range: 4 + i..<4 + i, replacement: [0x78], origin: .command))
            }
            try await h.settle()
            #expect(updates <= 2, "\(updates) updates for one burst")
            let text = try await h.js("return document.querySelector('p').textContent") as? String
            #expect(text == "text" + String(repeating: "x", count: 300))
        }

        // MARK: - Unchanged blocks are left alone

        private let longDocument = (0..<40).map { "Paragraph \($0) with **bold** and `code`.\n\n" }.joined() + "- a\n- b\n\n| x |\n|---|\n| y |\n"

        @Test("An edit touches only its own block, by node identity")
        func nodeIdentity() async throws {
            let h = try PreviewHarness(text: longDocument)
            defer { h.close() }
            try await h.settle()
            let tagged = try await h.js(tagNodes) as? Int ?? 0
            #expect(tagged > 300)

            let at = h.doc.buffer.text.utf16.count / 2
            try h.doc.buffer.apply(Patch(range: at..<at, replacement: Array("xyz".utf16), origin: .command))
            try await h.settle()
            let block = try await h.js("""
            const kids = [...document.getElementById('doc').children];
            return kids.findIndex(k => k.textContent.includes('xyz'));
            """) as? Int ?? -1
            #expect(block >= 0)
            let counts: [Int] = try await h.json(countChanges, ["skip": block])
            #expect(counts[0] == 0, "\(counts[0]) nodes replaced outside the edited block")
            #expect(counts[1] > 300)
            #expect(counts[2] == 0, "\(counts[2]) DOM changes outside the edited block")
        }

        @Test("Text above a block moves it without touching it")
        func textAbove() async throws {
            let h = try PreviewHarness(text: longDocument)
            defer { h.close() }
            try await h.settle()
            _ = try await h.js(tagNodes)
            try h.doc.buffer.apply(Patch(range: 0..<0, replacement: Array("New\n\n".utf16), origin: .command))
            try await h.settle()
            let counts: [Int] = try await h.json(countChanges, ["skip": 0])
            #expect(counts[0] == 0)
            #expect(counts[2] == 0, "\(counts[2]) DOM changes for text above")
        }

        @Test("A fresh render replaces every node, so the identity tests can fail")
        func identityControl() async throws {
            let h = try PreviewHarness(text: longDocument)
            defer { h.close() }
            try await h.settle()
            _ = try await h.js(tagNodes)
            try await h.freshRender()
            let counts: [Int] = try await h.json(countChanges, ["skip": -1])
            #expect(counts[0] == counts[1], "\(counts[0]) of \(counts[1]) nodes replaced")
            #expect(counts[0] > 300)
        }

        // MARK: - Scroll stays put

        private let scrollDocument = (0..<200).map { "Paragraph \($0) with some words in it to fill out the line.\n\n" }.joined()

        /// Scrolls well into the document, applies `edit`, and says how far the text
        /// at the top of the viewport moved.
        private func movement(_ text: String, disableAnchoring: Bool = false, edit: (Buffer) throws -> Void) async throws -> Double {
            let h = try PreviewHarness(text: text, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            _ = try await h.js("window.scrollTo(0, 3000)")
            if disableAnchoring { _ = try await h.js(removeAnchoring) }
            let before = try await h.js(watchTop) as? Double ?? .nan
            let scrolled = try await h.js("return scrollY") as? Double ?? 0
            #expect(scrolled > 2000, "the page has to scroll for this test to mean anything")
            try edit(h.doc.buffer)
            try await h.settle()
            await pump(for: 0.05)
            guard let after = try await h.js(watchedTop) as? Double else { throw HarnessFailure(description: "the watched text is gone") }
            return after - before
        }

        private func insert(_ s: String, at offset: Int) -> (Buffer) throws -> Void {
            { try $0.apply(Patch(range: offset..<offset, replacement: Array(s.utf16), origin: .command)) }
        }

        private var manyParagraphs: String { (0..<30).map { "Inserted \($0)\n\n" }.joined() }

        @Test("Scroll holds when text is added above the viewport")
        func scrollInsertAbove() async throws {
            #expect(abs(try await movement(scrollDocument, edit: insert(manyParagraphs, at: 0))) < 1)
        }

        @Test("Scroll holds when text is removed above the viewport")
        func scrollRemoveAbove() async throws {
            let moved = try await movement(scrollDocument) { try $0.apply(Patch(range: 0..<600, replacement: [], origin: .command)) }
            #expect(abs(moved) < 1)
        }

        @Test("Scroll holds when a block above the viewport grows")
        func scrollGrowAbove() async throws {
            let moved = try await movement(scrollDocument, edit: insert(String(repeating: "more words ", count: 300), at: 12))
            #expect(abs(moved) < 1)
        }

        @Test("Scroll holds when the block at the top of the viewport is a long list, edited above")
        func scrollInsideList() async throws {
            let list = (0..<400).map { "- item \($0)\n" }.joined()
            let moved = try await movement(list, edit: insert((0..<30).map { "- new \($0)\n" }.joined(), at: 22))
            #expect(abs(moved) < 1)
        }

        @Test("An edit below the viewport doesn't move anything")
        func scrollEditBelow() async throws {
            let text = scrollDocument
            let moved = try await movement(text, edit: insert(manyParagraphs, at: text.utf16.count))
            #expect(moved == 0)
        }

        @Test("With anchoring removed, the same edits move the text, so these tests can fail")
        func scrollControl() async throws {
            #expect(try await movement(scrollDocument, disableAnchoring: true, edit: insert(manyParagraphs, at: 0)) > 200)
            let moved = try await movement(scrollDocument, disableAnchoring: true) { try $0.apply(Patch(range: 0..<600, replacement: [], origin: .command)) }
            #expect(moved < -100)
            let list = (0..<400).map { "- item \($0)\n" }.joined()
            #expect(try await movement(list, disableAnchoring: true, edit: insert((0..<30).map { "- new \($0)\n" }.joined(), at: 22)) > 100)
        }

        // MARK: - Zero-diff

        private func save(_ doc: MarkdownDocument) async throws {
            var outcome: Result<Void, Error>?
            doc.save(to: doc.fileURL!, ofType: doc.fileType!, for: .saveOperation) { error in
                outcome = error.map { .failure($0) } ?? .success(())
            }
            guard await pump(until: { outcome != nil }) else { throw HarnessFailure(description: "the save never finished") }
            try outcome!.get()
        }

        @Test("With the preview open, open, no-op, save is byte-identical", arguments: previewFixtureNames)
        func noOpSave(name: String) async throws {
            let folder = try makeTemporaryFolder()
            let url = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixturesFolder.appendingPathComponent(name), to: url)
            let before = try sha256(url)
            let h = try PreviewHarness(url: url)
            defer { h.close() }
            try await h.settle()
            #expect(h.doc.isDocumentEdited == false, "\(name): the preview dirtied the document")
            try await save(h.doc)
            #expect(try sha256(url) == before, "\(name) changed")
        }

        @Test("With the preview open, an edit undone saves the original bytes", arguments: previewFixtureNames)
        func editUndoSave(name: String) async throws {
            let folder = try makeTemporaryFolder()
            let url = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixturesFolder.appendingPathComponent(name), to: url)
            let before = try sha256(url)
            let h = try PreviewHarness(url: url)
            defer { h.close() }
            try await h.settle()
            h.textView.setSelectedRange(NSRange(location: 0, length: 0))
            h.textView.insertText("x", replacementRange: h.textView.selectedRange())
            try await h.settle()
            h.controller.editor.undo()
            try await h.settle()
            try await save(h.doc)
            #expect(try sha256(url) == before, "\(name) changed")
        }

        // MARK: - Moving the document

        @Test("Saving somewhere else moves the page, so images resolve from there")
        func saveAs() async throws {
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
            let first = try makeTemporaryFolder(), second = try makeTemporaryFolder()
            try png.write(to: second.appendingPathComponent("here.png"))
            let url = first.appendingPathComponent("doc.md")
            try Data("![a](here.png)\n".utf8).write(to: url)
            let h = try PreviewHarness(url: url)
            defer { h.close() }
            try await h.settle()
            await pump(for: 0.2)
            func loaded() async throws -> Bool {
                try await h.js("const i = document.querySelector('img'); return i.complete && i.naturalWidth > 0") as? Bool ?? false
            }
            #expect(try await loaded() == false)

            h.doc.fileURL = second.appendingPathComponent("moved.md")
            await pump(for: 0.1)
            try await h.settle()
            #expect(await pump(until: { h.webView.url?.path == "/moved.md" }, timeout: 3))
            await pump(for: 0.2)
            #expect(try await loaded())
        }
    }
}
