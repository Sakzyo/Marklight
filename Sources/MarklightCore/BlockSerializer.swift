import Foundation

public struct RenderedEdit {
    public let patch: Patch
    public let document: IncrementalDocument
    public let caret: Int
    public let pending: Int?
}

public enum BlockSerializer {
    /// Interpret offsets against this snapshot only. Neither the page nor the
    /// serializer changes the buffer before the candidate has been checked.
    public static func edit(_ doc: IncrementalDocument, inputType: String, data: String?,
                            selection: Range<Int>, target: Range<Int>?, pending: Int?) -> RenderedEdit? {
        func valid(_ range: Range<Int>) -> Bool {
            range.lowerBound >= 0 && range.upperBound <= doc.units.count &&
                [range.lowerBound, range.upperBound].allSatisfy {
                    $0 == doc.units.count || !(0xDC00..<0xE000).contains(doc.units[$0])
                }
        }
        guard valid(selection), target.map(valid) ?? true else { return nil }
        let insertion: [UInt16]
        let deletion: Bool
        switch inputType {
        case "insertText", "insertReplacementText":
            guard let data, !data.isEmpty else { return nil }
            insertion = Array(data.utf16)
            guard !insertion.contains(where: { $0 == 0 || $0.isLineBreak }) else { return nil }
            deletion = false
        case "deleteContentBackward", "deleteContentForward", "deleteWordBackward", "deleteWordForward",
             "deleteSoftLineBackward", "deleteSoftLineForward", "deleteHardLineBackward", "deleteHardLineForward",
             "deleteByCut", "deleteContent":
            insertion = []
            deletion = true
        default: return nil
        }
        let range = target ?? selection
        guard range.lowerBound <= selection.upperBound, selection.lowerBound <= range.upperBound else { return nil }
        let start = range.lowerBound
        let index = doc.containing(start) ?? (start > 0 ? doc.containing(start - 1) : nil)
        let top = index.map { doc.block(at: $0) }
        let leaf = top.flatMap { editable($0, range: range, units: doc.units) }
        if let top, let index, let leaf {
            let emptyContainer = !leaf.isLeaf
            let span = emptyContainer ? start..<start : leaf.content
            guard let lo = boundary(range.lowerBound, in: leaf, span: span),
                  let hi = boundary(range.upperBound, in: leaf, span: span),
                  boundary(selection.lowerBound, in: leaf, span: span) != nil,
                  boundary(selection.upperBound, in: leaf, span: span) != nil else { return nil }
            var cut = lo..<hi
            if deletion && cut.isEmpty {
                guard (inputType == "deleteContentBackward" || inputType == "deleteContentForward"),
                      let chars = adjacentCharacter(leaf.atoms, at: lo, backward: inputType == "deleteContentBackward") else { return nil }
                cut = chars
            }
            guard !leaf.atoms[cut].contains(where: { $0.kind == .object }) else { return nil }
            let marks: [Mark]
            if !cut.isEmpty { marks = leaf.atoms[cut.lowerBound].marks }
            else if lo > 0, leaf.atoms[lo - 1].range.upperBound == start { marks = leaf.atoms[lo - 1].marks }
            else if lo < leaf.atoms.count, leaf.atoms[lo].range.lowerBound == start { marks = leaf.atoms[lo].marks }
            else { marks = [] }
            let editor = LeafEdit(doc: doc, topIndex: index, top: top, leaf: leaf, span: span)
            if let result = editor.replacing(cut, with: insertion, marks: marks) { return result }
            // After **When:** a letter cannot follow the closing delimiter. It
            // can still be typed by extending the adjacent formatting.
            if cut.isEmpty, !insertion.isEmpty, marks.isEmpty, lo > 0, !leaf.atoms[lo - 1].marks.isEmpty {
                return editor.replacing(cut, with: insertion, marks: leaf.atoms[lo - 1].marks)
            }
            return nil
        }
        guard !deletion, range.isEmpty, range == selection, start == pending || (start == 0 && doc.units.isEmpty) else { return nil }
        return LeafEdit(doc: doc, topIndex: nil, top: nil, leaf: nil, span: range).replacing(0..<0, with: insertion, marks: [])
    }

    private static func editable(_ b: Block, range: Range<Int>, units: [UInt16]) -> Block? {
        switch b.kind {
        case .paragraph, .heading:
            return !b.isOpaque && b.content.lowerBound <= range.lowerBound && range.upperBound <= b.content.upperBound ? b : nil
        case .item, .quote:
            if b.children.isEmpty, range.isEmpty, range.lowerBound == units.lineEnd(from: b.range.lowerBound) { return b }
            fallthrough
        case .list:
            for child in b.children {
                if let found = editable(child, range: range, units: units) { return found }
            }
            return nil
        default: return nil
        }
    }

    /// Offsets inside delimiters, escapes, entities or container prefixes cannot
    /// originate from a caret in a rendered text run.
    private static func boundary(_ offset: Int, in leaf: Block, span: Range<Int>) -> Int? {
        if offset == span.lowerBound { return 0 }
        if offset == span.upperBound { return leaf.atoms.count }
        for (i, a) in leaf.atoms.enumerated() {
            if a.range.lowerBound == offset { return i }
            if a.range.upperBound == offset, i + 1 == leaf.atoms.count || leaf.atoms[i + 1].range != a.range { return i + 1 }
        }
        return nil
    }

    private static func adjacentCharacter(_ atoms: [Atom], at i: Int, backward: Bool) -> Range<Int>? {
        let at = backward ? i - 1 : i
        guard atoms.indices.contains(at) else { return nil }
        let visible = atoms.map { atom -> UInt16 in
            switch atom.kind {
            case .softBreak, .hardBreak: return 10
            case .object: return 0xFFFC
            default: return atom.unit
            }
        }
        let text = String(decoding: visible, as: UTF16.self) as NSString
        let cluster = text.rangeOfComposedCharacterSequence(at: at)
        var lo = cluster.location, hi = NSMaxRange(cluster)
        // Multi-scalar entities share one indivisible source range.
        while lo > 0, atoms[lo - 1].range == atoms[lo].range { lo -= 1 }
        while hi < atoms.count, atoms[hi - 1].range == atoms[hi].range { hi += 1 }
        return lo..<hi
    }
}

private struct LeafEdit {
    let doc: IncrementalDocument
    let topIndex: Int?
    let top: Block?
    let leaf: Block?
    let span: Range<Int>

    func replacing(_ cut: Range<Int>, with text: [UInt16], marks: [Mark]) -> RenderedEdit? {
        var expected = leaf?.atoms ?? []
        let fresh = text.map { Atom(kind: .text, unit: $0, marks: marks, range: 0..<0) }
        expected.replaceSubrange(cut, with: fresh)
        var caretIndex = cut.lowerBound + fresh.count
        // Markdown cannot express whitespace just inside an emphasis delimiter.
        for i in expected.indices where expected[i].unit.isSpaceOrTab {
            let before = expected[i].marks
            let kept = before.filter { mark in
                guard [.strong, .emphasis, .strikethrough].contains(mark.kind) else { return true }
                var lo = i, hi = i
                while lo > 0, expected[lo - 1].unit.isSpaceOrTab, expected[lo - 1].marks.contains(mark) { lo -= 1 }
                while hi + 1 < expected.count, expected[hi + 1].unit.isSpaceOrTab, expected[hi + 1].marks.contains(mark) { hi += 1 }
                return lo > 0 && expected[lo - 1].marks.contains(mark) && hi + 1 < expected.count && expected[hi + 1].marks.contains(mark)
            }
            expected[i].marks = kept
        }
        if leaf?.kind == .paragraph, !cut.isEmpty {
            while expected.first?.unit.isSpaceOrTab == true { expected.removeFirst(); caretIndex = max(0, caretIndex - 1) }
        }
        var previous: [UInt16]?
        for mode in Spelling.allCases {
            var written = spelling(expected, mode: mode)
            if let leaf, case .item = leaf.kind, leaf.children.isEmpty, span.lowerBound > 0,
               !doc.units[span.lowerBound - 1].isSpaceOrTab { written.insert(32, at: 0) }
            if previous == written { continue }
            previous = written
            let diff = Patch.minimal(from: Array(doc.units[span]), to: written, origin: .rendered)
            let at = span.lowerBound
            let patch = Patch(range: (at + diff.range.lowerBound)..<(at + diff.range.upperBound), replacement: diff.replacement, origin: .rendered)
            let candidate = doc.applying(patch)
            guard let location = verified(candidate, patch: patch, expected: expected, caretIndex: caretIndex) else { continue }
            return RenderedEdit(patch: patch, document: candidate, caret: location.caret, pending: location.pending)
        }
        return nil
    }

    private enum Spelling: CaseIterable { case raw, escaped, widerCode, alternateMarks, escapeNearby }

    private func spelling(_ atoms: [Atom], mode: Spelling) -> [UInt16] {
        var out: [UInt16] = [], stack: [Mark] = []
        let syntax = Set(#"\*`_[]<>&~|"#.utf16)
        let startsBlock = Set("#-+>=.!:)".utf16)
        var overrides: [Int: ([UInt16], [UInt16])] = [:]
        for a in atoms where a.range.isEmpty {
            for mark in a.marks where overrides[mark.id] == nil {
                if case .link = mark.kind, mark.open == [91], mark.close == [93] || mark.close == [93,91,93],
                   let node = leaf.flatMap({ linkNode($0.inlines, mark: mark) }) {
                    let label = doc.units[(node.range.lowerBound + 1)..<(node.range.upperBound - mark.close.count)]
                    overrides[mark.id] = (mark.open, [93,91] + label + [93])
                } else if mode == .widerCode, mark.kind == .code {
                    let content = atoms.filter { $0.marks.contains(mark) }.map(\.unit)
                    var run = 0, longest = 0
                    for u in content { run = u == 96 ? run + 1 : 0; longest = max(longest, run) }
                    let fence = [UInt16](repeating: 96, count: longest + 1)
                    let pad: [UInt16] = content.first == 96 || content.last == 96 ? [32] : []
                    overrides[mark.id] = (fence + pad, pad + fence)
                }
            }
        }
        // Deleting within a shortcut link also changes its lookup label.
        if let leaf {
            for inline in allLinks(leaf.inlines) {
                guard case .mark(let mark) = inline.kind, mark.close == [93] || mark.close == [93,91,93],
                      overrides[mark.id] == nil else { continue }
                let old = leaf.atoms[inline.atoms]
                let kept = atoms.filter { $0.marks.contains(mark) }
                if kept.count != old.count {
                    overrides[mark.id] = (mark.open, [93,91] + doc.units[(inline.range.lowerBound + 1)..<(inline.range.upperBound - mark.close.count)] + [93])
                }
            }
        }
        func delimiter(_ mark: Mark, opening: Bool) -> [UInt16] {
            if let pair = overrides[mark.id] { return opening ? pair.0 : pair.1 }
            let original = opening ? mark.open : mark.close
            return mode == .alternateMarks && original.first == 95 ? original.map { _ in 42 } : original
        }
        var i = 0
        while i < atoms.count {
            let a = atoms[i]
            let keep = zip(stack, a.marks).prefix(while: { $0 == $1 }).count
            for m in stack[keep...].reversed() { out += delimiter(m, opening: false) }
            for m in a.marks[keep...] { out += delimiter(m, opening: true) }
            stack = a.marks
            let special = syntax.contains(a.unit) || startsBlock.contains(a.unit)
            let escape = mode != .raw && !stack.contains(where: { $0.kind == .code }) && special &&
                (a.range.isEmpty || mode == .escapeNearby && a.range.count == 1 && syntax.contains(a.unit))
            if escape { out.append(92) }
            if a.range.isEmpty { out.append(a.unit) }
            else { out += doc.units[a.range] }
            i += 1
            if a.range.count > 1 {
                while i < atoms.count, atoms[i].range == a.range { i += 1 }
            }
        }
        for m in stack.reversed() { out += delimiter(m, opening: false) }
        return out
    }

    private func allLinks(_ inlines: [Inline]) -> [Inline] {
        inlines.flatMap { node -> [Inline] in
            let children = allLinks(node.children)
            if case .mark(let m) = node.kind, case .link = m.kind { return [node] + children }
            return children
        }
    }

    private func linkNode(_ inlines: [Inline], mark: Mark) -> Inline? {
        allLinks(inlines).first { if case .mark(let m) = $0.kind { return m == mark }; return false }
    }

    private func verified(_ candidate: IncrementalDocument, patch: Patch, expected: [Atom], caretIndex: Int) -> (caret: Int, pending: Int?)? {
        let delta = patch.replacement.count - patch.range.count
        var pending: Int?
        var resultLeaf: Block?
        func sameText(_ actual: Block) -> Bool {
            guard !actual.isOpaque, actual.atoms.count == expected.count else { return false }
            for (a, b) in zip(expected, actual.atoms) {
                let aKind = a.kind == .ignored ? .text : a.kind
                let bKind = b.kind == .ignored ? .text : b.kind
                guard aKind == bKind, a.unit == b.unit else { return false }
                func semantic(_ m: Mark) -> Mark.Kind? {
                    if case .link = m.kind {
                        if m.open.isEmpty { return nil } // GFM bare URLs derive their target from the text.
                        if m.open == [60] { return .link(destination: "") }
                    }
                    return m.kind
                }
                let x = a.marks.compactMap(semantic), y = b.marks.compactMap(semantic)
                guard x == y else { return false }
                if a.kind == .object, !doc.units[a.range].elementsEqual(candidate.units[b.range]) { return false }
            }
            resultLeaf = actual
            return true
        }
        func sameTree(_ old: Block, _ new: Block) -> Bool {
            guard old.kind == new.kind else { return false }
            if old === leaf {
                if old.isLeaf { return sameText(new) }
                return new.children.count == 1 && new.children[0].kind == .paragraph && sameText(new.children[0])
            }
            if old.children.isEmpty {
                let shift = old.range.lowerBound >= patch.range.upperBound ? delta : 0
                return old.matches(new, shiftedBy: shift)
            }
            var j = 0
            for child in old.children {
                if child === leaf, expected.isEmpty, child.kind == .paragraph, new.children.count + 1 == old.children.count {
                    pending = span.lowerBound
                    continue
                }
                guard j < new.children.count, sameTree(child, new.children[j]) else { return false }
                j += 1
            }
            return j == new.children.count
        }
        var from = topIndex ?? 0
        var oldCount = 1, newCount = 1
        if let top, let index = topIndex {
            if expected.isEmpty, top === leaf, top.kind == .paragraph {
                newCount = 0
                pending = span.lowerBound
            } else {
                guard index < candidate.blockCount, sameTree(top, candidate.block(at: index)) else { return nil }
            }
        } else {
            oldCount = 0
            guard let index = candidate.containing(span.lowerBound) else { return nil }
            from = index
            let new = candidate.block(at: index)
            guard new.kind == .paragraph, new.content.lowerBound == span.lowerBound, sameText(new) else { return nil }
        }
        guard candidate.blockCount == doc.blockCount - oldCount + newCount else { return nil }
        // On the local path the parser reused every other entry. A full parse
        // can resolve remote reference links differently, so check those too.
        if candidate.usedFullParse {
            for i in 0..<doc.blockCount {
                if (from..<(from + oldCount)).contains(i) { continue }
                let before = i < from
                let j = before ? i : i + newCount - oldCount
                guard doc.block(at: i).matches(candidate.block(at: j), shiftedBy: before ? 0 : delta) else { return nil }
            }
        }
        if let pending { return (pending, pending) }
        guard let resultLeaf else { return nil }
        if resultLeaf.atoms.isEmpty { return (resultLeaf.content.lowerBound, nil) }
        let caret = caretIndex > 0 ? resultLeaf.atoms[caretIndex - 1].range.upperBound : resultLeaf.atoms[0].range.lowerBound
        return (caret, nil)
    }
}
