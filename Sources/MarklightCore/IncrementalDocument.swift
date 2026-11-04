import Foundation

/// An immutable snapshot for rendered editing. An untouched subtree keeps its
/// original coordinates; only its top-level entry moves when text above changes.
public struct IncrementalDocument {
    private struct Entry {
        let tree: Block
        var offset: Int
        var range: Range<Int> { tree.range.moved(by: offset) }
    }

    public let units: [UInt16]
    public let usedFullParse: Bool
    private var entries: [Entry]
    private let globalContext: Bool
    public var blockCount: Int { entries.count }

    public init(units: [UInt16]) {
        let parsed = ParsedDocument(units: units)
        self.units = units
        entries = parsed.root.children.map { Entry(tree: $0, offset: 0) }
        usedFullParse = true
        // cmark resolves definitions globally and caps their total expansion by
        // document size. A previously unclosed YAML fence can close far below.
        globalContext = Self.mayDefineReference(units[...]) ||
            (units.starts(with: [45, 45, 45]) && parsed.root.children.first?.kind != .frontMatter)
    }

    private init(units: [UInt16], entries: [Entry]) {
        self.units = units
        self.entries = entries
        usedFullParse = false
        globalContext = false
    }

    private static func mayDefineReference(_ slice: ArraySlice<UInt16>) -> Bool {
        var previous: UInt16?
        for unit in slice {
            if unit == 58 && previous == 93 { return true } // ]:
            previous = unit
        }
        return false
    }

    public func block(at index: Int) -> Block {
        let entry = entries[index]
        return entry.offset == 0 ? entry.tree : entry.tree.moved(by: entry.offset)
    }

    /// For a validated buffer patch. Fall back before committing the candidate
    /// whenever we cannot prove that the parsing context ends at the guards.
    public func applying(_ patch: Patch) -> Self {
        var next = units
        next.replaceSubrange(patch.range, with: patch.replacement)
        guard !globalContext, !patch.replacement.contains(where: \.isLineBreak),
              !units[patch.range].contains(where: \.isLineBreak),
              let edited = containing(patch.range.lowerBound),
              entries[edited].range.upperBound >= patch.range.upperBound else { return Self(units: next) }
        switch entries[edited].tree.kind {
        case .paragraph, .heading, .list, .quote: break
        default: return Self(units: next)
        }
        let first = max(edited - 1, 0), last = min(edited + 1, entries.count - 1)
        let start = lineStart(entries[first].range.lowerBound)
        let end = last + 1 < entries.count ? lineStart(entries[last + 1].range.lowerBound) : units.count
        let delta = patch.replacement.count - patch.range.count
        // The entire physical lines belong to the window. The guards must
        // survive the reparse exactly, including their ranges and inline marks.
        guard start <= patch.range.lowerBound, patch.range.upperBound <= end,
              !Self.mayDefineReference(next[start..<(end + delta)]),
              !(start == 0 && next.starts(with: [45, 45, 45])) else { return Self(units: next) }
        // A leading blank line at an interior restart prevents synthetic BOM
        // stripping and YAML front matter detection in the middle of the file.
        let prefix: [UInt16] = start == 0 ? [] : [10]
        let window = ParsedDocument(units: prefix + next[start..<(end + delta)])
        let trees = window.root.children
        let base = start - prefix.count
        guard trees.count == last - first + 1,
              trees[edited - first].kind == entries[edited].tree.kind else { return Self(units: next) }
        for index in first...last where index != edited {
            let expected = entries[index]
            let shift = expected.offset + (index > edited ? delta : 0) - base
            guard expected.tree.matches(trees[index - first], shiftedBy: shift) else { return Self(units: next) }
        }
        // A last-block sentry could conceal the start of a multiline construct
        // if its source were truncated. Require separation at the outer edges.
        guard (first == 0 || separated(before: start)),
              (last + 1 == entries.count || separated(before: end)) else { return Self(units: next) }
        var result = entries
        result[edited] = Entry(tree: trees[edited - first], offset: base)
        if delta != 0 {
            for index in result.indices where index > edited { result[index].offset += delta }
        }
        return Self(units: next, entries: result)
    }

    /// Find the first top-level block ending at or beyond the caret.
    func containing(_ at: Int) -> Int? {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].range.upperBound < at { lo = mid + 1 } else { hi = mid }
        }
        return lo < entries.count && entries[lo].range.lowerBound <= at ? lo : nil
    }

    private func lineStart(_ offset: Int) -> Int {
        var i = offset
        while i > 0, !units[i - 1].isLineBreak { i -= 1 }
        return i
    }

    /// A blank physical line before this restart point.
    private func separated(before offset: Int) -> Bool {
        guard offset > 0, units[offset - 1].isLineBreak else { return false }
        var i = offset - 1
        if units[i] == 10, i > 0, units[i - 1] == 13 { i -= 1 }
        while i > 0, units[i - 1].isSpaceOrTab { i -= 1 }
        return i == 0 || units[i - 1].isLineBreak
    }

    /// Used by the background idle check, on two snapshots of the same revision.
    public func agrees(with full: IncrementalDocument) -> Bool {
        entries.count == full.entries.count && zip(entries, full.entries).allSatisfy {
            $0.tree.matches($1.tree, shiftedBy: $0.offset - $1.offset)
        }
    }
}

private extension Range where Bound == Int {
    func moved(by delta: Int) -> Self { (lowerBound + delta)..<(upperBound + delta) }
}

private extension Mark {
    func matches(_ other: Mark) -> Bool {
        switch (kind, other.kind) {
        case let (.link(a), .link(b)): return a.utf8.elementsEqual(b.utf8) && open == other.open && close == other.close
        default: return kind == other.kind && open == other.open && close == other.close
        }
    }
}

private extension Inline {
    func moved(by delta: Int) -> Inline {
        let node = Inline(kind: kind, range: range.moved(by: delta), atoms: atoms)
        node.children = children.map { $0.moved(by: delta) }
        return node
    }

    func matches(_ other: Inline, shiftedBy delta: Int) -> Bool {
        guard range.moved(by: delta) == other.range, atoms == other.atoms,
              children.count == other.children.count else { return false }
        switch (kind, other.kind) {
        case (.run, .run): break
        case let (.mark(a), .mark(b)) where a.matches(b): break
        case let (.image(a, b), .image(c, d)) where a.utf8.elementsEqual(c.utf8) && b.utf8.elementsEqual(d.utf8): break
        case let (.html(a), .html(b)) where a.utf8.elementsEqual(b.utf8): break
        default: return false
        }
        return zip(children, other.children).allSatisfy { $0.matches($1, shiftedBy: delta) }
    }
}

extension Block {
    // Containers do not have a source content range. Their default 0..<0
    // doesn't acquire an offset when they move.
    private var hasContent: Bool {
        if case .code = kind { return true }
        return isLeaf
    }

    fileprivate func moved(by delta: Int) -> Block {
        let block = Block(kind: kind, range: range.moved(by: delta))
        block.content = hasContent ? content.moved(by: delta) : content
        block.rawHTML = rawHTML
        block.isOpaque = isOpaque
        block.columnAlignments = columnAlignments
        block.inlines = inlines.map { $0.moved(by: delta) }
        block.atoms = atoms.map {
            var atom = $0
            atom.range = atom.range.moved(by: delta)
            return atom
        }
        block.children = children.map {
            let child = $0.moved(by: delta)
            child.parent = block
            return child
        }
        return block
    }

    func matches(_ other: Block, shiftedBy delta: Int) -> Bool {
        guard kind == other.kind, range.moved(by: delta) == other.range,
              (hasContent ? content.moved(by: delta) : content) == other.content,
              isOpaque == other.isOpaque, rawHTML.utf8.elementsEqual(other.rawHTML.utf8),
              columnAlignments == other.columnAlignments, children.count == other.children.count,
              inlines.count == other.inlines.count, atoms.count == other.atoms.count else { return false }
        for (a, b) in zip(atoms, other.atoms) {
            guard a.kind == b.kind, a.unit == b.unit, a.range.moved(by: delta) == b.range,
                  a.marks.count == b.marks.count, zip(a.marks, b.marks).allSatisfy({ $0.matches($1) }) else { return false }
        }
        return zip(inlines, other.inlines).allSatisfy { $0.matches($1, shiftedBy: delta) } &&
            zip(children, other.children).allSatisfy { $0.matches($1, shiftedBy: delta) }
    }
}
