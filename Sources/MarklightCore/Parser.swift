import Foundation
import Markdown

/// An inline mark on a run of atoms. `open` and `close` are the exact source text
/// of its delimiters, so unchanged marks can be written back identically.
public struct Mark: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case strong, emphasis, strikethrough, code
        case link(destination: String)
    }

    public let kind: Kind
    public let id: Int
    public let open: [UInt16]
    public let close: [UInt16]

    public static func == (a: Mark, b: Mark) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One rendered unit. Text atoms are single UTF-16 units, so rendered offsets line
/// up with atom indexes. `range` is the source the atom came from: `\*` is one
/// atom covering two units.
public struct Atom: Sendable {
    public enum Kind: Sendable {
        case text, softBreak, hardBreak
        /// An image or inline HTML: one indivisible unit.
        case object
        /// Whitespace the parser ignores, such as trailing spaces.
        case ignored
    }

    public var kind: Kind
    public var unit: UInt16
    public var marks: [Mark]
    public var range: Range<Int>
}

public final class Inline {
    public enum Kind {
        case run
        case mark(Mark)
        case image(source: String, alt: String)
        case html(String)
    }

    public let kind: Kind
    public let range: Range<Int>
    public let atoms: Range<Int>
    public var children: [Inline] = []

    init(kind: Kind, range: Range<Int>, atoms: Range<Int>) {
        self.kind = kind
        self.range = range
        self.atoms = atoms
    }
}

public final class Block {
    public enum Kind: Equatable, Sendable {
        case document, frontMatter, paragraph, heading(Int), quote
        case list(ordered: Bool, start: Int), item(checked: Bool?)
        case code(info: String), html, rule
        case table, row(header: Bool), cell
    }

    public enum Alignment: Sendable {
        case left, center, right
    }

    public let kind: Kind
    public internal(set) var range: Range<Int>
    public internal(set) var children: [Block] = []
    public internal(set) weak var parent: Block?

    /// For leaves with text: paragraphs, headings, cells, and code.
    public internal(set) var atoms: [Atom] = []
    public internal(set) var inlines: [Inline] = []
    /// The source the atoms cover, which is what an edit to this block rewrites.
    public internal(set) var content: Range<Int> = 0..<0
    /// Its text couldn't be mapped to the source, so it can only be edited as source.
    public internal(set) var isOpaque = false
    /// For HTML blocks: the HTML, without any quote or list prefixes.
    public internal(set) var rawHTML = ""
    /// For tables: each column's alignment, where the delimiter row sets one.
    public internal(set) var columnAlignments: [Alignment?] = []

    init(kind: Kind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }

    public var isLeaf: Bool {
        switch kind {
        case .paragraph, .heading, .cell: return true
        default: return false
        }
    }

    var quoteDepth: Int {
        var depth = 0
        var ancestor = parent
        while let block = ancestor {
            if block.kind == .quote { depth += 1 }
            ancestor = block.parent
        }
        return depth
    }
}

extension UInt16 {
    var isLineBreak: Bool { self == 0x0A || self == 0x0D }
    var isSpaceOrTab: Bool { self == 0x20 || self == 0x09 }
    var isASCIIPunctuation: Bool {
        (0x21...0x2F).contains(self) || (0x3A...0x40).contains(self) || (0x5B...0x60).contains(self) || (0x7B...0x7E).contains(self)
    }
}

extension Array where Element == UInt16 {
    /// The unit at `i`, or nil past either end.
    func at(_ i: Int) -> UInt16? { i >= 0 && i < count ? self[i] : nil }

    /// The offset of the line break ending the line that contains `offset`.
    func lineEnd(from offset: Int) -> Int {
        var e = offset
        while let unit = at(e), !unit.isLineBreak { e += 1 }
        return e
    }

    /// The offset of the line after a line ending at `end`.
    func afterLineBreak(_ end: Int) -> Int {
        guard let unit = at(end) else { return end }
        if unit == 0x0D, at(end + 1) == 0x0A { return end + 2 }
        return unit.isLineBreak ? end + 1 : end
    }
}

/// Converts swift-markdown's 1-based (line, UTF-8 column) to UTF-16 offsets.
struct LineMap {
    let units: [UInt16]
    private var starts: [Int]

    init(_ units: [UInt16], from base: Int) {
        self.units = units
        starts = [base]
        var i = base
        while i < units.count {
            if units[i].isLineBreak {
                i = units.afterLineBreak(i)
                starts.append(i)
            } else {
                i += 1
            }
        }
    }

    func offset(_ location: SourceLocation) -> Int {
        guard location.line >= 1, location.line <= starts.count else { return units.count }
        var i = starts[location.line - 1]
        var bytes = location.column - 1
        while bytes > 0, i < units.count {
            let unit = units[i]
            if unit < 0x80 { bytes -= 1; i += 1 }
            else if unit < 0x800 { bytes -= 2; i += 1 }
            else if (0xD800..<0xDC00).contains(unit) { bytes -= 4; i += 2 }
            else { bytes -= 3; i += 1 }
        }
        return Swift.min(i, units.count)
    }
}

/// A parsed document: block tree, with an atom list for every leaf.
///
/// Only block ranges come from cmark. Its inline positions are wrong after a
/// backslash break, on lazy continuation lines, and in a few other cases
/// (`spikes/spike1-ranges/REPORT.md`), so inline ranges come from walking each
/// leaf's source with the AST as a guide.
public final class ParsedDocument {
    public let units: [UInt16]
    public let root: Block
    private let lines: LineMap
    private let entities = EntityDecoder()
    private var nextMark = 0

    public init(units: [UInt16]) {
        self.units = units
        let bodyStart = ParsedDocument.frontMatterEnd(units)
        lines = LineMap(units, from: bodyStart)
        root = Block(kind: .document, range: 0..<units.count)
        if bodyStart > 0 {
            let block = Block(kind: .frontMatter, range: 0..<bodyStart)
            block.parent = root
            root.children.append(block)
        }
        // Smart punctuation would make the text differ from the source.
        let document = Document(parsing: String(decoding: units[bodyStart...], as: UTF16.self), options: [.disableSmartOpts])
        root.children += document.children.compactMap { build($0, parent: root) }
    }

    /// Every block with text, in document order.
    public func leaves() -> [Block] {
        func walk(_ block: Block, into out: inout [Block]) {
            if block.isLeaf {
                out.append(block)
            } else if case .code = block.kind {
                out.append(block)
            } else {
                for child in block.children { walk(child, into: &out) }
            }
        }
        var out: [Block] = []
        walk(root, into: &out)
        return out
    }

    /// YAML front matter: `---` on the first line, closed by `---` or `...`.
    private static func frontMatterEnd(_ units: [UInt16]) -> Int {
        func isFence(_ line: ArraySlice<UInt16>, closing: Bool) -> Bool {
            let trimmed = Array(line.reversed().drop { $0.isSpaceOrTab }.reversed())
            return trimmed == [0x2D, 0x2D, 0x2D] || (closing && trimmed == [0x2E, 0x2E, 0x2E])
        }
        let firstEnd = units.lineEnd(from: 0)
        guard isFence(units[0..<firstEnd], closing: false), firstEnd < units.count else { return 0 }
        var line = units.afterLineBreak(firstEnd)
        while line < units.count {
            let end = units.lineEnd(from: line)
            if isFence(units[line..<end], closing: true) { return units.afterLineBreak(end) }
            line = units.afterLineBreak(end)
        }
        return 0
    }

    private func range(_ node: Markup) -> Range<Int>? {
        guard let r = node.range else { return nil }
        let lo = lines.offset(r.lowerBound), hi = lines.offset(r.upperBound)
        return lo <= hi ? lo..<hi : nil
    }

    private func build(_ node: Markup, parent: Block) -> Block? {
        guard let r = range(node) else { return nil }
        let block: Block
        switch node {
        case is Paragraph: block = Block(kind: .paragraph, range: r)
        case let n as Heading: block = Block(kind: .heading(n.level), range: r)
        case is BlockQuote: block = Block(kind: .quote, range: r)
        case is UnorderedList: block = Block(kind: .list(ordered: false, start: 0), range: r)
        case let n as OrderedList: block = Block(kind: .list(ordered: true, start: Int(n.startIndex)), range: r)
        case let n as ListItem: block = Block(kind: .item(checked: n.checkbox.map { $0 == .checked }), range: r)
        case let n as CodeBlock: block = Block(kind: .code(info: n.language ?? ""), range: r)
        case let n as HTMLBlock:
            block = Block(kind: .html, range: r)
            block.rawHTML = n.rawHTML
        case is ThematicBreak:
            // cmark's range takes in the line break.
            block = Block(kind: .rule, range: r.lowerBound..<units.lineEnd(from: r.lowerBound))
        case let n as Table:
            block = Block(kind: .table, range: r)
            block.columnAlignments = n.columnAlignments.map { alignment in
                switch alignment {
                case .left: return .left
                case .center: return .center
                case .right: return .right
                case nil: return nil
                }
            }
        case is Table.Head: block = Block(kind: .row(header: true), range: r)
        case is Table.Row: block = Block(kind: .row(header: false), range: r)
        case is Table.Cell: block = Block(kind: .cell, range: r)
        default: return nil
        }
        block.parent = parent
        if let table = node as? Table {
            let rows: [Markup] = [table.head] + table.body.rows.map { $0 }
            block.children = rows.compactMap { build($0, parent: block) }
        } else if block.isLeaf {
            anchorLeaf(block, node: node)
        } else if let code = node as? CodeBlock {
            anchorCode(block, code: code)
        } else {
            block.children = node.children.compactMap { build($0, parent: block) }
        }
        return block
    }

    private func anchorLeaf(_ block: Block, node: Markup) {
        var start = block.range.lowerBound
        var isATX = false
        switch block.kind {
        case .cell:
            while start < block.range.upperBound, units[start].isSpaceOrTab { start += 1 }
            if start >= block.range.upperBound || units[start] == 0x7C {
                // An empty cell, whose cmark range runs into the closing pipe.
                let at = Swift.min(block.range.lowerBound + 1, block.range.upperBound)
                block.content = at..<at
                return
            }
        case .heading where units.at(start) == 0x23:
            isATX = true
            while units.at(start) == 0x23 { start += 1 }
            while let unit = units.at(start), unit.isSpaceOrTab { start += 1 }
        default:
            break
        }
        var walker = InlineWalker(units: units, start: start, quoteDepth: block.quoteDepth, nextMark: nextMark, entities: entities)
        do {
            block.inlines = try walker.walk(Array(node.children), marks: [])
        } catch {
            block.isOpaque = true
            block.content = start..<Swift.max(start, block.range.upperBound)
            return
        }
        let lineEnd = units.lineEnd(from: block.range.upperBound)
        if case .heading = block.kind {
            if isATX {
                // Closing #s are part of the block, even where cmark stops short.
                var e = units.lineEnd(from: walker.cursor)
                while e > walker.cursor, units[e - 1].isSpaceOrTab { e -= 1 }
                block.range = block.range.lowerBound..<Swift.max(block.range.upperBound, e)
            } else {
                // cmark can run past a setext underline into the next line.
                let underline = units.afterLineBreak(units.lineEnd(from: walker.cursor))
                block.range = block.range.lowerBound..<units.lineEnd(from: underline)
            }
        } else if block.kind == .paragraph {
            walker.addTrailingWhitespace(limit: lineEnd)
        }
        block.atoms = walker.atoms
        block.content = start..<walker.cursor
        nextMark = walker.nextMark
    }

    /// Code text is literal, but each source line may carry a container prefix.
    private func anchorCode(_ block: Block, code: CodeBlock) {
        var codeLines = code.code.components(separatedBy: "\n").map { Array($0.utf16) }
        if codeLines.last?.isEmpty == true { codeLines.removeLast() }
        var lineStart = block.range.lowerBound
        var s = lineStart
        while let unit = units.at(s), unit.isSpaceOrTab { s += 1 }
        if units.at(s) == 0x60 || units.at(s) == 0x7E {
            lineStart = units.afterLineBreak(units.lineEnd(from: lineStart))
        }
        var atoms: [Atom] = []
        let first = lineStart
        var last = lineStart
        for (k, line) in codeLines.enumerated() {
            let e = units.lineEnd(from: lineStart)
            guard e - lineStart >= line.count, Array(units[(e - line.count)..<e]) == line else {
                block.isOpaque = true
                block.content = block.range
                return
            }
            for i in 0..<line.count {
                let at = e - line.count + i
                atoms.append(Atom(kind: .text, unit: line[i], marks: [], range: at..<at + 1))
            }
            let next = units.afterLineBreak(e)
            // The break covers the next line's container prefix too.
            let following = k + 1 < codeLines.count ? Swift.max(next, units.lineEnd(from: next) - codeLines[k + 1].count) : next
            atoms.append(Atom(kind: .softBreak, unit: 0, marks: [], range: e..<following))
            last = e
            lineStart = next
        }
        if !atoms.isEmpty { atoms.removeLast() }
        block.atoms = atoms
        block.content = first..<Swift.max(first, last)
        block.inlines = [Inline(kind: .run, range: block.content, atoms: 0..<atoms.count)]
    }
}

/// Decodes `&...;`, with cmark as the authority on what counts as an entity.
private final class EntityDecoder {
    private var cache: [String: [UInt16]?] = [:]

    func decode(_ entity: String) -> [UInt16]? {
        if let known = cache[entity] { return known }
        let parsed = Document(parsing: "x" + entity).child(at: 0) as? Paragraph
        let text = parsed.map { String($0.plainText.dropFirst()) } ?? entity
        let result: [UInt16]? = text == entity ? nil : Array(text.utf16)
        cache[entity] = result
        return result
    }
}

private struct WalkFailure: Error {}

/// Walks a leaf's source guided by its AST, recording where every rendered unit
/// came from. Throws if the source doesn't line up with the AST, which leaves the
/// block opaque rather than wrongly mapped.
private struct InlineWalker {
    let u: [UInt16]
    var cursor: Int
    let quoteDepth: Int
    var atoms: [Atom] = []
    var nextMark: Int
    let entities: EntityDecoder

    init(units: [UInt16], start: Int, quoteDepth: Int, nextMark: Int, entities: EntityDecoder) {
        u = units
        cursor = start
        self.quoteDepth = quoteDepth
        self.nextMark = nextMark
        self.entities = entities
    }

    mutating func walk(_ nodes: [Markup], marks: [Mark]) throws -> [Inline] {
        var out: [Inline] = []
        for node in nodes { out += try walkOne(node, marks: marks) }
        return out
    }

    private mutating func walkOne(_ node: Markup, marks: [Mark]) throws -> [Inline] {
        let start = cursor
        let firstAtom = atoms.count
        switch node {
        case let text as Text:
            try matchText(Array(text.string.utf16), marks: marks)
            return runs(from: firstAtom)

        case is SoftBreak, is LineBreak:
            try skipBreak()
            atoms.append(Atom(kind: node is LineBreak ? .hardBreak : .softBreak, unit: 0, marks: marks, range: start..<cursor))
            return [Inline(kind: .run, range: start..<cursor, atoms: firstAtom..<atoms.count)]

        case is Strong, is Emphasis, is Strikethrough:
            guard let delimiter = u.at(cursor), delimiter == 0x2A || delimiter == 0x5F || delimiter == 0x7E else { throw WalkFailure() }
            var n = node is Strong ? 2 : 1
            if node is Strikethrough {
                n = 0
                while u.at(cursor + n) == 0x7E { n += 1 }
                n = Swift.min(n, 2)
            }
            guard (0..<n).allSatisfy({ u.at(cursor + $0) == delimiter }) else { throw WalkFailure() }
            let delimiters = Array(u[cursor..<cursor + n])
            cursor += n
            let kind: Mark.Kind = node is Strong ? .strong : node is Emphasis ? .emphasis : .strikethrough
            let mark = makeMark(kind, open: delimiters, close: delimiters)
            let children = try walk(Array(node.children), marks: marks + [mark])
            guard (0..<n).allSatisfy({ u.at(cursor + $0) == delimiter }) else { throw WalkFailure() }
            cursor += n
            let inline = Inline(kind: .mark(mark), range: start..<cursor, atoms: firstAtom..<atoms.count)
            inline.children = children
            return [inline]

        case let code as InlineCode:
            return [try matchCode(code.code, marks: marks, start: start)]

        case let link as Link:
            return [try matchLink(link, marks: marks, start: start)]

        case let image as Image:
            guard u.at(cursor) == 0x21, u.at(cursor + 1) == 0x5B else { throw WalkFailure() }
            cursor += 2
            var alt = InlineWalker(units: u, start: cursor, quoteDepth: quoteDepth, nextMark: nextMark, entities: entities)
            _ = try alt.walk(Array(image.children), marks: [])
            cursor = alt.cursor
            guard u.at(cursor) == 0x5D else { throw WalkFailure() }
            cursor += 1
            skipLinkTail()
            atoms.append(Atom(kind: .object, unit: 0, marks: marks, range: start..<cursor))
            return [Inline(kind: .image(source: image.source ?? "", alt: image.plainText), range: start..<cursor, atoms: firstAtom..<atoms.count)]

        case let html as InlineHTML:
            let raw = Array(html.rawHTML.utf16)
            guard cursor + raw.count <= u.count, Array(u[cursor..<cursor + raw.count]) == raw else { throw WalkFailure() }
            cursor += raw.count
            atoms.append(Atom(kind: .object, unit: 0, marks: marks, range: start..<cursor))
            return [Inline(kind: .html(html.rawHTML), range: start..<cursor, atoms: firstAtom..<atoms.count)]

        default:
            throw WalkFailure()
        }
    }

    private mutating func makeMark(_ kind: Mark.Kind, open: [UInt16], close: [UInt16]) -> Mark {
        nextMark += 1
        return Mark(kind: kind, id: nextMark, open: open, close: close)
    }

    /// Groups atoms into 1:1 runs, with every escape or entity a run of its own.
    private func runs(from first: Int) -> [Inline] {
        var out: [Inline] = []
        var i = first
        while i < atoms.count {
            let r = atoms[i].range
            var j = i + 1
            if r.count == 1 {
                while j < atoms.count, atoms[j].range.count == 1, atoms[j].range.lowerBound == atoms[j - 1].range.upperBound { j += 1 }
            } else {
                while j < atoms.count, atoms[j].range == r { j += 1 } // an entity decoding to several units
            }
            out.append(Inline(kind: .run, range: r.lowerBound..<atoms[j - 1].range.upperBound, atoms: i..<j))
            i = j
        }
        return out
    }

    private mutating func matchText(_ text: [UInt16], marks: [Mark]) throws {
        var i = 0
        while i < text.count {
            let unit = text[i]
            guard let source = u.at(cursor) else { throw WalkFailure() }
            if source == 0x5C, let next = u.at(cursor + 1), next.isASCIIPunctuation, next == unit {
                atoms.append(Atom(kind: .text, unit: unit, marks: marks, range: cursor..<cursor + 2))
                cursor += 2
                i += 1
            } else if source == 0x26, let (length, decoded) = entity(at: cursor), i + decoded.count <= text.count,
                      Array(text[i..<i + decoded.count]) == decoded {
                for d in decoded { atoms.append(Atom(kind: .text, unit: d, marks: marks, range: cursor..<cursor + length)) }
                cursor += length
                i += decoded.count
            } else if source == unit {
                atoms.append(Atom(kind: .text, unit: unit, marks: marks, range: cursor..<cursor + 1))
                cursor += 1
                i += 1
            } else {
                throw WalkFailure()
            }
        }
    }

    private func entity(at start: Int) -> (Int, [UInt16])? {
        var e = start + 1
        while let unit = u.at(e), e - start < 34 {
            if unit == 0x3B {
                guard e > start + 1 else { return nil }
                return entities.decode(String(decoding: u[start...e], as: UTF16.self)).map { (e - start + 1, $0) }
            }
            let isAlphanumeric = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x23
            guard isAlphanumeric else { return nil }
            e += 1
        }
        return nil
    }

    private mutating func skipBreak() throws {
        while let unit = u.at(cursor), unit.isSpaceOrTab { cursor += 1 }
        if u.at(cursor) == 0x5C { cursor += 1 }
        try skipLineBreakAndPrefix()
    }

    private mutating func skipLineBreakAndPrefix() throws {
        guard let unit = u.at(cursor), unit.isLineBreak else { throw WalkFailure() }
        cursor = u.afterLineBreak(cursor)
        while let unit = u.at(cursor), unit.isSpaceOrTab { cursor += 1 }
        for _ in 0..<quoteDepth where u.at(cursor) == 0x3E {
            cursor += 1
            while let unit = u.at(cursor), unit.isSpaceOrTab { cursor += 1 }
        }
    }

    private mutating func matchCode(_ code: String, marks: [Mark], start: Int) throws -> Inline {
        var ticks = 0
        while u.at(cursor + ticks) == 0x60 { ticks += 1 }
        guard ticks > 0 else { throw WalkFailure() }
        var e = cursor + ticks
        var closing: Int?
        while e < u.count {
            guard u[e] == 0x60 else { e += 1; continue }
            var n = 0
            while u.at(e + n) == 0x60 { n += 1 }
            if n == ticks { closing = e; break }
            e += n
        }
        guard let closeStart = closing else { throw WalkFailure() }
        var lo = cursor + ticks
        var hi = closeStart
        let target = Array(code.utf16)
        // cmark strips one space from each side when both are present.
        let isEdge: (UInt16) -> Bool = { $0 == 0x20 || $0.isLineBreak }
        if hi - lo >= 2, isEdge(u[lo]), isEdge(u[hi - 1]), u[lo..<hi].contains(where: { !isEdge($0) }) {
            if u[lo] == 0x0D, u[lo + 1] == 0x0A { lo += 1 }
            lo += 1
            if u[hi - 1] == 0x0A, u[hi - 2] == 0x0D { hi -= 1 }
            hi -= 1
        }
        let mark = makeMark(.code, open: Array(u[start..<lo]), close: Array(u[hi..<closeStart + ticks]))
        let first = atoms.count
        var i = 0
        cursor = lo
        while cursor < hi {
            guard i < target.count else { throw WalkFailure() }
            if u[cursor].isLineBreak {
                let s = cursor
                try skipLineBreakAndPrefix()
                atoms.append(Atom(kind: .text, unit: 0x20, marks: marks + [mark], range: s..<Swift.min(cursor, hi)))
            } else if u[cursor] == 0x5C, u.at(cursor + 1) == 0x7C, target[i] == 0x7C { // \| in a table cell
                atoms.append(Atom(kind: .text, unit: 0x7C, marks: marks + [mark], range: cursor..<cursor + 2))
                cursor += 2
            } else {
                guard u[cursor] == target[i] else { throw WalkFailure() }
                atoms.append(Atom(kind: .text, unit: u[cursor], marks: marks + [mark], range: cursor..<cursor + 1))
                cursor += 1
            }
            i += 1
        }
        cursor = closeStart + ticks
        let inline = Inline(kind: .mark(mark), range: start..<cursor, atoms: first..<atoms.count)
        inline.children = runs(from: first)
        return inline
    }

    private mutating func matchLink(_ link: Link, marks: [Mark], start: Int) throws -> Inline {
        let destination = link.destination ?? ""
        let first = atoms.count
        var mark: Mark
        var close: Int? = nil
        if u.at(cursor) == 0x5B {
            cursor += 1
            // The tail isn't known until the text is walked, and the atoms need
            // the finished mark, so walk once to find it.
            var probe = self
            _ = try probe.walk(Array(link.children), marks: marks)
            guard probe.u.at(probe.cursor) == 0x5D else { throw WalkFailure() }
            let textEnd = probe.cursor
            probe.cursor += 1
            probe.skipLinkTail()
            mark = makeMark(.link(destination: destination), open: [0x5B], close: Array(u[textEnd..<probe.cursor]))
            close = probe.cursor
        } else if u.at(cursor) == 0x3C {
            cursor += 1
            mark = makeMark(.link(destination: destination), open: [0x3C], close: [0x3E])
        } else {
            mark = makeMark(.link(destination: destination), open: [], close: [])
        }
        let children = try walk(Array(link.children), marks: marks + [mark])
        if let close {
            cursor = close
        } else if mark.close == [0x3E] {
            guard u.at(cursor) == 0x3E else { throw WalkFailure() }
            cursor += 1
        }
        let inline = Inline(kind: .mark(mark), range: start..<cursor, atoms: first..<atoms.count)
        inline.children = children
        return inline
    }

    /// After `]`: an inline tail `(dest "title")`, a reference `[label]`, or nothing.
    private mutating func skipLinkTail() {
        if u.at(cursor) == 0x28, let end = inlineTailEnd(from: cursor) {
            cursor = end
        } else if u.at(cursor) == 0x5B {
            var e = cursor + 1
            while let unit = u.at(e), unit != 0x5D, !unit.isLineBreak { e += unit == 0x5C ? 2 : 1 }
            if u.at(e) == 0x5D { cursor = e + 1 }
        }
    }

    private func inlineTailEnd(from open: Int) -> Int? {
        var e = open + 1
        let quoted = quoteDepth > 0
        func skipSpace(_ e: inout Int) {
            while let unit = u.at(e), unit.isSpaceOrTab || unit.isLineBreak || (unit == 0x3E && quoted) { e += 1 }
        }
        skipSpace(&e)
        if u.at(e) == 0x3C {
            e += 1
            while let unit = u.at(e), unit != 0x3E {
                if unit.isLineBreak { return nil }
                e += unit == 0x5C ? 2 : 1
            }
            e += 1
        } else {
            var depth = 0
            while let unit = u.at(e) {
                if unit == 0x5C { e += 2; continue }
                if unit == 0x28 { depth += 1 }
                if unit == 0x29 {
                    if depth == 0 { break }
                    depth -= 1
                }
                if unit.isSpaceOrTab || unit.isLineBreak { break }
                e += 1
            }
        }
        skipSpace(&e)
        if let quote = u.at(e), quote == 0x22 || quote == 0x27 || quote == 0x28 {
            let closer: UInt16 = quote == 0x28 ? 0x29 : quote
            e += 1
            while let unit = u.at(e), unit != closer { e += unit == 0x5C ? 2 : 1 }
            guard u.at(e) == closer else { return nil }
            e += 1
            skipSpace(&e)
        }
        return u.at(e) == 0x29 ? e + 1 : nil
    }

    /// Whitespace after the last inline. cmark ignores it, but it's still in the
    /// file, and has to stay reachable while someone types "hello world".
    mutating func addTrailingWhitespace(limit: Int) {
        while cursor < limit, let unit = u.at(cursor), unit.isSpaceOrTab {
            atoms.append(Atom(kind: .ignored, unit: unit, marks: [], range: cursor..<cursor + 1))
            cursor += 1
        }
    }
}
