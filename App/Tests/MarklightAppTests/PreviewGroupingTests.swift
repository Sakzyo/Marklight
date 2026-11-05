import AppKit
import Foundation
import MarklightCore
import Testing
@testable import MarklightApp

private let paragraphs = (0..<200).map { "Paragraph number \($0).\n\n" }.joined()

/// `[wrappers, blocks, largest wrapper, empty wrappers, stray nodes, wrappers
/// claiming an offset, 1 if blocks are in source order]`
private let shape = """
const chunks = [...document.getElementById('doc').childNodes];
const blocks = chunks.flatMap(c => [...c.childNodes]);
return [chunks.length, blocks.length, Math.max(...chunks.map(c => c.childNodes.length)),
        chunks.filter(c => !c.hasChildNodes()).length,
        chunks.concat(blocks).filter(n => n.nodeType !== 1).length,
        chunks.filter(c => c._base !== undefined).length,
        blocks.every((b, i) => !i || blocks[i - 1]._base < b._base) ? 1 : 0];
"""

extension PreviewSuites {
    @MainActor @Suite("Block grouping")
    struct PreviewGroupingTests {
        private func offset(of text: String, in h: PreviewHarness) -> Int {
            (h.doc.buffer.text as NSString).range(of: text).location
        }

        /// The patched page must match a whole fresh render, node for node.
        private func checkFresh(_ h: PreviewHarness) async throws {
            let patched = try await h.dom()
            try await h.freshRender()
            #expect(try await h.dom() == patched)
        }

        @Test("Blocks are grouped in order, and a wrapper leaves no visible trace")
        func grouped() async throws {
            let h = try PreviewHarness(text: paragraphs)
            defer { h.close() }
            try await h.settle()
            let found: [Int] = try await h.json(shape)
            #expect(found == [4, 200, 64, 0, 0, 0, 1])
            let gaps: [Double] = try await h.json("""
            const tops = [...document.querySelectorAll('#doc p')].map(p => p.getBoundingClientRect().top);
            return [...new Set(tops.slice(1).map((top, i) => top - tops[i]))];
            """)
            #expect(gaps.count == 1, "\(gaps)")
        }

        @Test("A selection between blocks maps to the neighbouring blocks")
        func betweenBlocks() async throws {
            let h = try PreviewHarness(text: paragraphs)
            defer { h.close() }
            try await h.settle()
            let select = """
            const root = document.getElementById('doc');
            const node = index === null ? root : root.children[index];
            const end = last === null ? node.childNodes.length : last;
            getSelection().empty();
            getSelection().setBaseAndExtent(node, first, node, end);
            return marklight.selection();
            """
            func selected(_ wrapper: Int?, _ first: Int, _ last: Int?) async throws -> [Int]? {
                try await h.js(select, ["index": wrapper as Any? ?? NSNull(), "first": first, "last": last as Any? ?? NSNull()]) as? [Int]
            }
            let second = offset(of: "Paragraph number 64.", in: h), third = offset(of: "Paragraph number 128.", in: h)
            let end = offset(of: "Paragraph number 199.", in: h) + "Paragraph number 199.".utf16.count
            #expect(try await selected(nil, 0, nil) == [0, end], "everything, from the root")
            #expect(try await selected(nil, 1, 2) == [second, third], "whole wrappers, from the root")
            #expect(try await selected(0, 0, nil) == [0, second], "the end of a wrapper is the start of the next")
            #expect(try await selected(3, 0, nil) == [offset(of: "Paragraph number 192.", in: h), end], "the end of the last wrapper is the end of the document")
            #expect(try await selected(1, 1, 2) == [offset(of: "Paragraph number 65.", in: h), offset(of: "Paragraph number 66.", in: h)])
        }

        @Test("Removing all of a wrapper's blocks removes the wrapper")
        func emptied() async throws {
            let h = try PreviewHarness(text: paragraphs)
            defer { h.close() }
            try await h.settle()
            let from = offset(of: "Paragraph number 60.", in: h), to = offset(of: "Paragraph number 135.", in: h)
            try h.doc.buffer.apply(Patch(range: from..<to, replacement: [], origin: .command))
            try await h.settle()
            let found: [Int] = try await h.json(shape)
            #expect(found == [3, 125, 60, 0, 0, 0, 1])
            try await checkFresh(h)
        }

        @Test("Blocks added at the end join the last wrapper")
        func appended() async throws {
            let h = try PreviewHarness(text: paragraphs)
            defer { h.close() }
            try await h.settle()
            let end = h.doc.buffer.units.count
            try h.doc.buffer.apply(Patch(range: end..<end, replacement: Array("One more.\n\nAnd another.\n".utf16), origin: .command))
            try await h.settle()
            let found: [Int] = try await h.json(shape)
            #expect(found == [4, 202, 64, 0, 0, 0, 1])
            try await checkFresh(h)
        }

        @Test("A large insertion is spread across wrappers and keeps the caret")
        func spread() async throws {
            let h = try PreviewHarness(text: paragraphs, windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await h.settle()
            let caret = offset(of: "Paragraph number 80.", in: h) + 4
            h.window.makeFirstResponder(h.webView)
            _ = try await h.js("document.getElementById('doc').focus(); marklight.select(at, at)", ["at": caret])
            let inserted = Array((0..<300).map { "Inserted \($0).\n\n" }.joined().utf16)
            let at = offset(of: "Paragraph number 70.", in: h)
            try h.doc.buffer.apply(Patch(range: at..<at, replacement: inserted, origin: .command))
            try await h.settle()
            let found: [Int] = try await h.json(shape)
            #expect(found[1] == 500 && found[3...] == [0, 0, 0, 1], "\(found)")
            #expect(found[2] <= 128, "\(found[2]) blocks in one wrapper")
            #expect(try await h.js("return marklight.selection()") as? [Int] == [caret + inserted.count, caret + inserted.count])
            let live = try await h.js("return getSelection().anchorNode.parentElement.closest('p').textContent") as? String
            #expect(live == "Paragraph number 80.")
            try await checkFresh(h)
        }

        /// What WebKit can do while an input method owns the DOM.
        private static let damage = [
            "root.children[2].remove(); root.children[0].firstChild.remove(); root.children[0].remove();",
            "root.append('stray');",
            "root.children[1].append('stray');",
            "root.children[1].firstChild.remove();",
            "root.prepend(root.children[1].firstChild);",
        ]

        @Test("A composition that damages the wrappers is repaired", arguments: damage)
        func repaired(_ damage: String) async throws {
            let h = try PreviewHarness(text: paragraphs, windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await h.settle()
            let caret = offset(of: "Paragraph number 100.", in: h) + 4
            h.window.makeFirstResponder(h.webView)
            let before = try await h.dom()
            let version = h.doc.buffer.version
            _ = try await h.js("""
            const root = document.getElementById('doc');
            root.focus();
            marklight.select(at, at);
            root.dispatchEvent(new CompositionEvent('compositionstart', {bubbles: true}));
            \(damage)
            root.dispatchEvent(new CompositionEvent('compositionend', {bubbles: true, data: ''}));
            """, ["at": caret])
            await pump(for: 0.1)
            let found: [Int] = try await h.json(shape)
            #expect(found[1...] == [200, 64, 0, 0, 0, 1], "\(found)")
            #expect(try await h.dom() == before)
            #expect(h.doc.buffer.version == version)
            #expect(try await h.js("return marklight.selection()") as? [Int] == [caret, caret])
        }

        @Test("The editing host draws no focus ring, which costs a walk of every box on every paint")
        func noFocusRing() async throws {
            let h = try PreviewHarness(text: "text\n", windowClass: RenderedKeyWindow.self)
            defer { h.close() }
            try await h.settle()
            h.window.makeFirstResponder(h.webView)
            _ = try await h.js("document.getElementById('doc').focus(); marklight.select(1, 1)")
            key(h, "x", code: 7)
            #expect(await pump(until: { h.doc.buffer.text == "txext\n" }))
            let outline = try await h.js("""
            const root = document.getElementById('doc');
            return [root.matches(':focus-visible'), getComputedStyle(root).outlineStyle];
            """) as? [Any]
            #expect(outline?.first as? Bool == true, "the rule has to win while the ring would otherwise show")
            #expect(outline?.last as? String == "none")
        }
    }
}
