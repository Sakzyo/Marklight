import Foundation
import Markdown

struct AnchorError: Error { let reason: String }

private var entityCache: [String: [UInt16]?] = [:]

/// What `&...;` decodes to, or nil if it isn't an entity. cmark is the authority.
private func decodeEntity(_ s: String) -> [UInt16]? {
    if let cached = entityCache[s] { return cached }
    let text = Paragraphs.firstText(Document(parsing: "x" + s)) ?? "x" + s
    let decoded = String(text.dropFirst())
    let result: [UInt16]? = decoded == s ? nil : Array(decoded.utf16)
    entityCache[s] = result
    return result
}

private enum Paragraphs {
    static func firstText(_ d: Document) -> String? {
        (d.child(at: 0) as? Paragraph).map { $0.plainText }
    }
}

/// Walks a leaf's source guided by its AST, recording where every rendered unit
/// came from. Only block ranges are taken from cmark, which sidesteps the inline
/// position bugs in the Spike 1 report.
struct Anchorer {
    let u: [UInt16]
    var c: Int
    let quoteDepth: Int
    var atoms: [Atom] = []
    var nextMark: Int

    init(units: [UInt16], start: Int, quoteDepth: Int, nextMark: Int) {
        u = units
        c = start
        self.quoteDepth = quoteDepth
        self.nextMark = nextMark
    }

    private func at(_ i: Int) -> UInt16? { i < u.count ? u[i] : nil }

    private func slice(_ r: Range<Int>) -> [UInt16] { Array(u[r]) }

    mutating func walk(_ nodes: [Markup], marks: [Mark]) throws -> [Inline] {
        var out: [Inline] = []
        for node in nodes {
            out.append(contentsOf: try walkOne(node, marks: marks))
        }
        return out
    }

    private mutating func walkOne(_ node: Markup, marks: [Mark]) throws -> [Inline] {
        let start = c
        let firstAtom = atoms.count
        switch node {
        case let text as Text:
            try matchText(Array(text.string.utf16), marks: marks)
            return splitRuns(from: firstAtom)

        case is SoftBreak, is LineBreak:
            let hard = node is LineBreak
            try skipBreak()
            atoms.append(Atom(kind: hard ? .hardBreak : .softBreak, marks: marks, range: start..<c))
            return [Inline(kind: .run, range: start..<c, atoms: firstAtom..<atoms.count)]

        case is Strong, is Emphasis, is Strikethrough:
            let delim = u[safe: c] ?? 0
            guard delim == 0x2A || delim == 0x5F || delim == 0x7E else { throw AnchorError(reason: "no delimiter at \(c)") }
            var n = node is Strong ? 2 : 1
            if node is Strikethrough {
                n = 0
                while at(c + n) == 0x7E { n += 1 }
                n = min(n, 2)
            }
            guard (0..<n).allSatisfy({ at(c + $0) == delim }) else { throw AnchorError(reason: "short delimiter at \(c)") }
            let open = slice(c..<c + n)
            c += n
            let kind: Mark.Kind = node is Strong ? .strong : (node is Emphasis ? .em : .strike)
            let mark = makeMark(kind, open: open, close: open)
            let children = try walk(Array(node.children), marks: marks + [mark])
            guard (0..<n).allSatisfy({ at(c + $0) == delim }) else { throw AnchorError(reason: "no closing delimiter at \(c)") }
            c += n
            let inline = Inline(kind: .mark(mark), range: start..<c, atoms: firstAtom..<atoms.count)
            inline.children = children
            return [inline]

        case let code as InlineCode:
            return [try matchCode(code.code, marks: marks, start: start)]

        case let link as Link:
            return [try matchLink(link, marks: marks, start: start)]

        case let image as Image:
            guard at(c) == 0x21, at(c + 1) == 0x5B else { throw AnchorError(reason: "no image at \(c)") }
            c += 2
            var sub = Anchorer(units: u, start: c, quoteDepth: quoteDepth, nextMark: nextMark)
            _ = try sub.walk(Array(image.children), marks: [])
            c = sub.c
            guard at(c) == 0x5D else { throw AnchorError(reason: "no ] in image at \(c)") }
            c += 1
            skipLinkTail()
            atoms.append(Atom(kind: .object, marks: marks, range: start..<c))
            return [Inline(kind: .image(src: image.source ?? "", alt: image.plainText), range: start..<c, atoms: firstAtom..<atoms.count)]

        case let html as InlineHTML:
            let raw = Array(html.rawHTML.utf16)
            guard c + raw.count <= u.count, Array(u[c..<c + raw.count]) == raw else { throw AnchorError(reason: "inline html mismatch at \(c)") }
            c += raw.count
            atoms.append(Atom(kind: .object, marks: marks, range: start..<c))
            return [Inline(kind: .html(html.rawHTML), range: start..<c, atoms: firstAtom..<atoms.count)]

        default:
            throw AnchorError(reason: "unhandled inline \(type(of: node))")
        }
    }

    private mutating func makeMark(_ kind: Mark.Kind, open: [UInt16], close: [UInt16]) -> Mark {
        nextMark += 1
        return Mark(kind: kind, id: nextMark, open: open, close: close)
    }

    /// Groups atoms into 1:1 runs, with every escape or entity its own run.
    private func splitRuns(from first: Int) -> [Inline] {
        var out: [Inline] = []
        var i = first
        while i < atoms.count {
            let r = atoms[i].range!
            var j = i + 1
            if r.count == 1 {
                while j < atoms.count, atoms[j].range!.count == 1, atoms[j].range!.lowerBound == atoms[j - 1].range!.upperBound { j += 1 }
            } else {
                while j < atoms.count, atoms[j].range! == r { j += 1 } // entity decoding to several units
            }
            out.append(Inline(kind: .run, range: r.lowerBound..<atoms[j - 1].range!.upperBound, atoms: i..<j))
            i = j
        }
        return out
    }

    private mutating func matchText(_ t: [UInt16], marks: [Mark]) throws {
        var i = 0
        while i < t.count {
            let unit = t[i]
            guard let src = at(c) else { throw AnchorError(reason: "text past end of source") }
            if src == 0x5C, let next = at(c + 1), next.isASCIIPunctuation, next == unit {
                atoms.append(Atom(kind: .text, unit: unit, marks: marks, range: c..<c + 2))
                c += 2
                i += 1
                continue
            }
            if src == 0x26, let (length, decoded) = entity(at: c), i + decoded.count <= t.count, Array(t[i..<i + decoded.count]) == decoded {
                for d in decoded { atoms.append(Atom(kind: .text, unit: d, marks: marks, range: c..<c + length)) }
                c += length
                i += decoded.count
                continue
            }
            guard src == unit else {
                throw AnchorError(reason: "text mismatch at \(c): source \(src), text \(unit)")
            }
            atoms.append(Atom(kind: .text, unit: unit, marks: marks, range: c..<c + 1))
            c += 1
            i += 1
        }
    }

    private func entity(at start: Int) -> (Int, [UInt16])? {
        var e = start + 1
        while let unit = at(e), e - start < 34 {
            if unit == 0x3B {
                guard e > start + 1 else { return nil }
                let s = String(decoding: u[start...e], as: UTF16.self)
                return decodeEntity(s).map { (e - start + 1, $0) }
            }
            let alnum = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x23
            guard alnum else { return nil }
            e += 1
        }
        return nil
    }

    private mutating func skipBreak() throws {
        while let unit = at(c), unit.isSpaceOrTab { c += 1 }
        if at(c) == 0x5C { c += 1 }
        try skipNewlineAndPrefix()
    }

    private mutating func skipNewlineAndPrefix() throws {
        guard let unit = at(c), unit.isLineBreak else { throw AnchorError(reason: "expected line break at \(c)") }
        c += (unit == 0x0D && at(c + 1) == 0x0A) ? 2 : 1
        skipLinePrefix()
    }

    private mutating func skipLinePrefix() {
        while let unit = at(c), unit.isSpaceOrTab { c += 1 }
        for _ in 0..<quoteDepth where at(c) == 0x3E {
            c += 1
            while let unit = at(c), unit.isSpaceOrTab { c += 1 }
        }
    }

    private mutating func matchCode(_ code: String, marks: [Mark], start: Int) throws -> Inline {
        var ticks = 0
        while at(c + ticks) == 0x60 { ticks += 1 }
        guard ticks > 0 else { throw AnchorError(reason: "no backticks at \(c)") }
        var e = c + ticks
        var close: Int?
        while e < u.count {
            if u[e] == 0x60 {
                var n = 0
                while at(e + n) == 0x60 { n += 1 }
                if n == ticks { close = e; break }
                e += n
            } else {
                e += 1
            }
        }
        guard let closeStart = close else { throw AnchorError(reason: "unterminated code at \(c)") }
        var lo = c + ticks
        var hi = closeStart
        let target = Array(code.utf16)
        // cmark strips one space from each side when both are present.
        let edgeSpace: (UInt16) -> Bool = { $0 == 0x20 || $0.isLineBreak }
        if hi - lo >= 2, edgeSpace(u[lo]), edgeSpace(u[hi - 1]), u[lo..<hi].contains(where: { !edgeSpace($0) }) {
            if u[lo] == 0x0D, u[lo + 1] == 0x0A { lo += 1 }
            lo += 1
            if u[hi - 1] == 0x0A, u[hi - 2] == 0x0D { hi -= 1 }
            hi -= 1
        }
        let mark = makeMark(.code, open: slice(start..<lo), close: slice(hi..<closeStart + ticks))
        let first = atoms.count
        var i = 0
        c = lo
        while c < hi {
            guard i < target.count else { throw AnchorError(reason: "code longer than node at \(c)") }
            if u[c].isLineBreak {
                let s = c
                try skipNewlineAndPrefix()
                atoms.append(Atom(kind: .text, unit: 0x20, marks: marks + [mark], range: s..<min(c, hi)))
            } else if u[c] == 0x5C, at(c + 1) == 0x7C, target[i] == 0x7C { // \| in a table cell
                atoms.append(Atom(kind: .text, unit: 0x7C, marks: marks + [mark], range: c..<c + 2))
                c += 2
            } else {
                guard u[c] == target[i] else { throw AnchorError(reason: "code mismatch at \(c)") }
                atoms.append(Atom(kind: .text, unit: u[c], marks: marks + [mark], range: c..<c + 1))
                c += 1
            }
            i += 1
        }
        c = closeStart + ticks
        let inline = Inline(kind: .mark(mark), range: start..<c, atoms: first..<atoms.count)
        inline.children = splitRuns(from: first).map { run in run }
        return inline
    }

    private mutating func matchLink(_ link: Link, marks: [Mark], start: Int) throws -> Inline {
        let dest = link.destination ?? ""
        let first = atoms.count
        if at(c) == 0x5B {
            c += 1
            // The mark's delimiters aren't known until the tail is scanned, so walk
            // once to find the tail, then again with the finished mark.
            var probe = self
            _ = try probe.walk(Array(link.children), marks: marks)
            guard probe.at(probe.c) == 0x5D else { throw AnchorError(reason: "no ] at \(probe.c)") }
            let textEnd = probe.c
            var tail = probe
            tail.c += 1
            tail.skipLinkTail()
            let mark = makeMark(.link(dest), open: [0x5B], close: slice(textEnd..<tail.c))
            let children = try walk(Array(link.children), marks: marks + [mark])
            c = tail.c
            let inline = Inline(kind: .mark(mark), range: start..<c, atoms: first..<atoms.count)
            inline.children = children
            return inline
        }
        var open: [UInt16] = []
        var close: [UInt16] = []
        if at(c) == 0x3C {
            open = [0x3C]
            close = [0x3E]
            c += 1
        }
        let mark = makeMark(.link(dest), open: open, close: close)
        let children = try walk(Array(link.children), marks: marks + [mark])
        if !close.isEmpty {
            guard at(c) == 0x3E else { throw AnchorError(reason: "no > at \(c)") }
            c += 1
        }
        let inline = Inline(kind: .mark(mark), range: start..<c, atoms: first..<atoms.count)
        inline.children = children
        return inline
    }

    /// After `]`: an inline tail `(dest "title")`, a reference `[label]`, or nothing.
    private mutating func skipLinkTail() {
        if at(c) == 0x28, let end = inlineTailEnd(from: c) {
            c = end
        } else if at(c) == 0x5B {
            var e = c + 1
            while let unit = at(e), unit != 0x5D, !unit.isLineBreak {
                e += unit == 0x5C ? 2 : 1
            }
            if at(e) == 0x5D { c = e + 1 }
        }
    }

    private func inlineTailEnd(from open: Int) -> Int? {
        var e = open + 1
        func skipSpace(_ e: inout Int) {
            while let unit = at(e), unit.isSpaceOrTab || unit.isLineBreak || unit == 0x3E && quoteDepth > 0 { e += 1 }
        }
        skipSpace(&e)
        if at(e) == 0x3C {
            e += 1
            while let unit = at(e), unit != 0x3E {
                if unit.isLineBreak { return nil }
                e += unit == 0x5C ? 2 : 1
            }
            e += 1
        } else {
            var depth = 0
            while let unit = at(e) {
                if unit == 0x5C { e += 2; continue }
                if unit == 0x28 { depth += 1 }
                if unit == 0x29 { if depth == 0 { break }; depth -= 1 }
                if unit.isSpaceOrTab || unit.isLineBreak { break }
                e += 1
            }
        }
        skipSpace(&e)
        if let q = at(e), q == 0x22 || q == 0x27 || q == 0x28 {
            let closer: UInt16 = q == 0x28 ? 0x29 : q
            e += 1
            while let unit = at(e), unit != closer { e += unit == 0x5C ? 2 : 1 }
            guard at(e) == closer else { return nil }
            e += 1
            skipSpace(&e)
        }
        return at(e) == 0x29 ? e + 1 : nil
    }

    /// Whitespace after the last inline, up to the end of the line. cmark ignores
    /// it, but it has to stay visible while someone types "hello world".
    mutating func trailingWhitespace(limit: Int) {
        while c < limit, let unit = at(c), unit.isSpaceOrTab {
            atoms.append(Atom(kind: .ignored, unit: unit, range: c..<c + 1))
            c += 1
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

/// A parsed document: block tree with atoms for every leaf.
public final class DocModel {
    public let units: [UInt16]
    public let root: Block
    private let lines: LineMap
    private var nextMark = 0

    public init(units: [UInt16]) {
        self.units = units
        lines = LineMap(units)
        let text = String(decoding: units, as: UTF16.self)
        root = Block(kind: .document, range: 0..<units.count)
        let document = Document(parsing: text, options: [.disableSmartOpts])
        root.children = document.children.compactMap { build($0, parent: root) }
    }

    private func range(_ node: Markup) -> Range<Int>? {
        guard let r = node.range else { return nil }
        let lo = lines.offset(line: r.lowerBound.line, column: r.lowerBound.column)
        let hi = lines.offset(line: r.upperBound.line, column: r.upperBound.column)
        return lo <= hi ? lo..<hi : nil
    }

    private func build(_ node: Markup, parent: Block) -> Block? {
        guard let r = range(node) else { return nil }
        let block: Block
        switch node {
        case is Paragraph: block = Block(kind: .paragraph, range: r)
        case let h as Heading: block = Block(kind: .heading(h.level), range: r)
        case is BlockQuote: block = Block(kind: .quote, range: r)
        case is UnorderedList: block = Block(kind: .list(ordered: false, start: 0), range: r)
        case let o as OrderedList: block = Block(kind: .list(ordered: true, start: Int(o.startIndex)), range: r)
        case let i as ListItem:
            let checked: Bool? = i.checkbox.map { $0 == .checked }
            block = Block(kind: .item(checked: checked), range: r)
        case let c as CodeBlock: block = Block(kind: .code(info: c.language ?? ""), range: r)
        case is HTMLBlock: block = Block(kind: .html, range: r)
        case is ThematicBreak: block = Block(kind: .rule, range: r)
        case is Table: block = Block(kind: .table, range: r)
        case is Table.Head: block = Block(kind: .row(header: true), range: r)
        case is Table.Row: block = Block(kind: .row(header: false), range: r)
        case is Table.Cell: block = Block(kind: .cell, range: r)
        default: return nil
        }
        block.parent = parent

        if node is Table.Body {
            return nil
        }
        if let table = node as? Table {
            if let head = build(table.head, parent: block) { block.children.append(head) }
            for row in table.body.rows { if let b = build(row, parent: block) { block.children.append(b) } }
            return block
        }
        if block.isLeaf {
            anchorLeaf(block, node: node)
        } else if case .code = block.kind, let code = node as? CodeBlock {
            anchorCode(block, code: code)
        } else {
            block.children = node.children.compactMap { build($0, parent: block) }
        }
        return block
    }

    private func anchorLeaf(_ block: Block, node: Markup) {
        var start = block.range.lowerBound
        let lineEnd = lineEnd(from: block.range.upperBound)
        if case .cell = block.kind {
            while start < block.range.upperBound, units[start].isSpaceOrTab { start += 1 }
            if start >= block.range.upperBound || units[start] == 0x7C {
                // Empty cell. cmark's range runs into the closing pipe.
                let at = min(block.range.lowerBound + 1, block.range.upperBound)
                block.content = at..<at
                return
            }
        } else if case .heading = block.kind, units[safe: start] == 0x23 {
            while units[safe: start] == 0x23 { start += 1 }
            while let u = units[safe: start], u.isSpaceOrTab { start += 1 }
        }
        var anchorer = Anchorer(units: units, start: start, quoteDepth: block.quoteDepth, nextMark: nextMark)
        do {
            block.inlines = try anchorer.walk(Array(node.children), marks: [])
            if case .cell = block.kind {
                // Cell text ends before the padding.
            } else if case .heading = block.kind, units[safe: block.range.lowerBound] == 0x23 {
                // Trailing spaces and closing #s stay outside the content.
            } else {
                anchorer.trailingWhitespace(limit: lineEnd)
            }
            block.atoms = anchorer.atoms
            block.content = start..<anchorer.c
            nextMark = anchorer.nextMark
            if case .heading = block.kind, units[safe: block.range.lowerBound] != 0x23 {
                // Setext: clamp to the underline (cmark may run past it; Spike 1, bug 5).
                var e = anchorer.c
                while let u = units[safe: e], !u.isLineBreak { e += 1 }
                if units[safe: e] == 0x0D, units[safe: e + 1] == 0x0A { e += 1 }
                e += 1
                while let u = units[safe: e], !u.isLineBreak { e += 1 }
                block.range = block.range.lowerBound..<min(e, units.count)
            }
        } catch {
            block.opaque = true
            block.opaqueReason = (error as? AnchorError)?.reason ?? "\(error)"
            block.content = start..<max(start, block.range.upperBound)
            block.atoms = []
            block.inlines = []
        }
    }

    private func lineEnd(from offset: Int) -> Int {
        var e = offset
        while let u = units[safe: e], !u.isLineBreak { e += 1 }
        return e
    }

    /// Code text is literal, but each source line may carry a container prefix.
    private func anchorCode(_ block: Block, code: CodeBlock) {
        var codeLines = code.code.components(separatedBy: "\n").map { Array($0.utf16) }
        if codeLines.last?.isEmpty == true { codeLines.removeLast() }
        var lineStart = block.range.lowerBound
        var fenced = false
        var s = lineStart
        while let u = units[safe: s], u.isSpaceOrTab { s += 1 }
        if units[safe: s] == 0x60 || units[safe: s] == 0x7E {
            fenced = true
            lineStart = lineEnd(from: lineStart)
            lineStart = afterBreak(lineStart)
        }
        var atoms: [Atom] = []
        let first = lineStart
        var last = lineStart
        for (k, line) in codeLines.enumerated() {
            let e = lineEnd(from: lineStart)
            guard e - lineStart >= line.count, Array(units[(e - line.count)..<e]) == line else {
                block.opaque = true
                block.opaqueReason = "code line mismatch at \(lineStart)"
                return
            }
            for i in 0..<line.count {
                atoms.append(Atom(kind: .text, unit: line[i], range: (e - line.count + i)..<(e - line.count + i + 1)))
            }
            let next = afterBreak(e)
            // The break covers the next line's container prefix too.
            let following = k + 1 < codeLines.count ? max(next, lineEnd(from: next) - codeLines[k + 1].count) : next
            atoms.append(Atom(kind: .softBreak, range: e..<following))
            last = e
            lineStart = next
        }
        if !atoms.isEmpty { atoms.removeLast() }
        block.atoms = atoms
        block.content = first..<max(first, fenced && codeLines.isEmpty ? first : last)
        block.inlines = [Inline(kind: .run, range: block.content, atoms: 0..<atoms.count)]
    }

    private func afterBreak(_ e: Int) -> Int {
        guard let u = units[safe: e] else { return e }
        if u == 0x0D, units[safe: e + 1] == 0x0A { return e + 2 }
        return u.isLineBreak ? e + 1 : e
    }
}
