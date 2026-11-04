import Foundation
import Testing
@testable import MarklightCore

private struct EditSeed {
    var value: UInt64
    mutating func index(_ n: Int) -> Int {
        value = value &* 2862933555777941757 &+ 3037000493
        return Int((value >> 32) % UInt64(n))
    }
}

@Suite("Rendered edit fuzz")
struct RenderedEditFuzzTests {
    @Test func seededEdits() throws {
        let ops = ["letter", "literal", "backspace", "forward", "replace", "word", "line"]
        var applied = Array(repeating: 0, count: ops.count)
        var refused = applied
        let steps = ProcessInfo.processInfo.environment["MARKLIGHT_LARGE_FUZZ"] == "1" ? 160 : 10
        for name in Fixtures.all {
            let original = try Fixtures.data(name)
            let buffer = Buffer(contentsOf: original)
            var doc = IncrementalDocument(units: buffer.units)
            let seed = name.utf8.reduce(UInt64(97081)) { $0 &* 31 &+ UInt64($1) }
            var random = EditSeed(value: seed)
            var pending = buffer.units.isEmpty ? 0 : nil
            for step in 0..<steps {
                let before = ParsedDocument(units: buffer.units)
                let tops = before.root.children
                let leaves = before.leaves().filter { leaf in
                    guard !leaf.isOpaque else { return false }
                    switch leaf.kind { case .paragraph, .heading: return true; default: return false }
                }
                let leaf = leaves.isEmpty ? nil : leaves[random.index(leaves.count)]
                let positions: [Int]
                if let leaf {
                    let edges = Set(leaf.atoms.flatMap { [$0.range.lowerBound, $0.range.upperBound] } + [leaf.content.lowerBound, leaf.content.upperBound])
                    positions = edges.sorted().filter { $0 == buffer.units.count || !(0xDC00..<0xE000).contains(buffer.units[$0]) }
                } else if let pending { positions = [pending] }
                else { break }
                let at = positions[random.index(positions.count)], other = positions[random.index(positions.count)]
                var selected = at..<at, target: Range<Int>?, data: String?
                let type: String, op = random.index(ops.count)
                switch op {
                case 0: type = "insertText"; data = "x"
                case 1:
                    type = "insertText"
                    let pieces = ["*", "__z__", "`", "# ", "👩🏽‍💻", "中文", "&amp;", "\\", "["]
                    data = pieces[random.index(pieces.count)]
                case 2: type = "deleteContentBackward"
                case 3: type = "deleteContentForward"
                case 4:
                    type = "insertReplacementText"; data = "e\u{301}"
                    selected = min(at, other)..<max(at, other)
                case 5: type = "deleteWordBackward"; target = min(at, other)..<at
                default: type = "deleteSoftLineForward"; target = at..<max(at, other)
                }
                let context = "\(name), seed \(seed), step \(step) \(type) \(selected)"
                guard let edit = BlockSerializer.edit(doc, inputType: type, data: data, selection: selected, target: target, pending: pending) else {
                    refused[op] += 1
                    try checkAgainstFullParse(doc, expected: buffer.units, context: context)
                    continue
                }
                applied[op] += 1
                let patch = edit.patch
                var independent = before.units
                independent.replaceSubrange(patch.range, with: patch.replacement)
                try buffer.apply(patch, selectionBefore: selected)
                #expect(buffer.units == independent, "\(context)")
                try checkAgainstFullParse(edit.document, expected: independent, context: context)
                let full = ParsedDocument(units: independent)
                let oldHTML = HTMLRenderer.render(before).blocks, newHTML = HTMLRenderer.render(full).blocks
                let delta = patch.replacement.count - patch.range.count
                for (i, block) in tops.enumerated() {
                    // The original leaf's top-level container may change. Every
                    // other top-level block must retain its meaning and location.
                    if block.range.lowerBound <= at && at <= block.range.upperBound { continue }
                    let shift = block.range.upperBound <= patch.range.lowerBound ? 0 : delta
                    let base = oldHTML[i].base + shift
                    #expect(newHTML.contains { $0.base == base && $0.html.utf8.elementsEqual(oldHTML[i].html.utf8) }, "\(context) outside block \(i)")
                }
                let opaqueBefore = before.leaves().filter(\.isOpaque).count
                #expect(full.leaves().filter(\.isOpaque).count == opaqueBefore, "\(context)")
                for leaf in full.leaves() where !leaf.isOpaque {
                    if case .code = leaf.kind { continue }
                    #expect(rebuild(leaf.atoms, independent) == Array(independent[leaf.content]), "\(context) at \(leaf.range)")
                }
                pending = edit.pending
                doc = edit.document
            }
            while buffer.canUndo { buffer.undo() }
            #expect(!buffer.isDirty && buffer.serialized() == original, "\(name), seed \(seed)")
        }
        for i in ops.indices {
            print("Rendered fuzz \(ops[i]): \(applied[i]) applied, \(refused[i]) refused")
            #expect(applied[i] > 0, "\(ops[i]) never applied")
        }
    }
}
