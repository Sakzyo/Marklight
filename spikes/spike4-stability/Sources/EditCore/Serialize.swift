import Foundation

/// How new text gets written. Unchanged atoms always reuse their source bytes.
public struct WriteOptions {
    public var escape: Escape = .none
    /// Also escape existing plain text, for when typed text pairs up with it.
    public var reescapeExisting = false
    public var eol: [UInt16] = [0x0A]
    public var linePrefix: [UInt16] = []
    /// `_` can't open or close mid-word. Stars for new marks, or for all of them.
    public var stars = Stars.none
    /// Links whose text changed: `[shortcut]` is written `[text][shortcut]`.
    public var explicitLinks: Set<Mark> = []
    /// Fences for code that now contains backticks.
    public var widenCode = false
    /// In a table cell a pipe needs its backslash even inside code.
    public var inCell = false
    public enum Stars { case none, newMarks, all }
    public enum Escape { case none, inline, block }
    public init() {}
}

public enum Serializer {
    /// Delimiters of whitespace-edged marks are invalid, so strip marks from
    /// leading and trailing whitespace of each run.
    public static func normalize(_ atoms: [Atom]) -> [Atom] {
        func prefix(_ atom: Atom, _ m: Mark) -> ArraySlice<Mark> {
            atom.marks[..<(atom.marks.firstIndex(of: m) ?? 0)]
        }
        var out = atoms
        for i in atoms.indices where atoms[i].isSpace {
            out[i].marks.removeAll { m in
                guard m.kind == .strong || m.kind == .em || m.kind == .strike else { return false }
                // A run breaks where the marks outside it change: the writer has
                // to close and reopen there, so that's a delimiter edge too.
                func joined(_ a: Int, _ b: Int) -> Bool {
                    atoms[a].marks.contains(m) && atoms[b].marks.contains(m) && prefix(atoms[a], m) == prefix(atoms[b], m)
                }
                var l = i
                while l > 0, joined(l - 1, l), atoms[l - 1].isSpace { l -= 1 }
                var r = i
                while r + 1 < atoms.count, joined(r, r + 1), atoms[r + 1].isSpace { r += 1 }
                let leftEdge = l == 0 || !joined(l - 1, l)
                let rightEdge = r == atoms.count - 1 || !joined(r, r + 1)
                return leftEdge || rightEdge
            }
        }
        return out
    }

    /// `caret` is an atom index. `caretOffset` reports where it landed in the
    /// output: right after atom `caret - 1`, inside that atom's marks.
    public static func write(_ atoms: [Atom], source u: [UInt16], options: WriteOptions = WriteOptions(),
                             caret: Int? = nil, caretOffset: UnsafeMutablePointer<Int>? = nil) -> [UInt16] {
        var out: [UInt16] = []
        var stack: [Mark] = []
        var i = 0
        func opening(_ m: Mark) -> [UInt16] {
            if options.widenCode, m.kind == .code, let f = fence(m, atoms) { return f.open }
            return starred(m, m.open, options)
        }
        func closing(_ m: Mark) -> [UInt16] {
            if options.widenCode, m.kind == .code, let f = fence(m, atoms) { return f.close }
            if options.explicitLinks.contains(m), let explicit = m.explicitClose { return explicit }
            return starred(m, m.close, options)
        }
        while i < atoms.count {
            let atom = atoms[i]
            var common = 0
            while common < stack.count, common < atom.marks.count, stack[common] == atom.marks[common] { common += 1 }
            while stack.count > common { out += closing(stack.removeLast()) }
            for m in atom.marks[common...] {
                out += opening(m)
                stack.append(m)
            }
            if caret == 0, i == 0 { caretOffset?.pointee = out.count }
            let lineStart = atoms[..<i].allSatisfy { $0.kind == .text && (0x30...0x39).contains($0.unit) }
            let reescape = options.reescapeExisting && atom.kind == .text && atom.range?.count == 1
                && (inlineSpecials.contains(atom.unit) || (lineStart && blockSpecials.contains(atom.unit)))
                && !atom.marks.contains { $0.kind == .code }
            if let r = atom.range, !reescape {
                var j = i + 1 // an entity spans several atoms but is written once
                while j < atoms.count, atoms[j].range == r, r.count > 1 { j += 1 }
                out += u[r]
                if let caret, caret > i, caret <= j { caretOffset?.pointee = out.count }
                i = j
                continue
            }
            switch atom.kind {
            case .softBreak: out += options.eol + options.linePrefix
            case .hardBreak: out += [0x5C] + options.eol + options.linePrefix
            default:
                let inCode = atom.marks.contains { $0.kind == .code }
                if !inCode, reescape || needsEscape(atoms, i, options.escape) { out.append(0x5C) }
                else if inCode, options.inCell, atom.unit == 0x7C { out.append(0x5C) }
                out.append(atom.unit)
            }
            i += 1
            if caret == i { caretOffset?.pointee = out.count }
        }
        if atoms.isEmpty { caretOffset?.pointee = 0 }
        while let m = stack.popLast() { out += closing(m) }
        return out
    }

    /// A fence longer than any backtick run inside, padded if the code touches it.
    private static func fence(_ m: Mark, _ atoms: [Atom]) -> (open: [UInt16], close: [UInt16])? {
        let text = atoms.filter { $0.marks.contains(m) }.map { $0.unit }
        var longest = 0, run = 0
        for u in text {
            run = u == 0x60 ? run + 1 : 0
            longest = max(longest, run)
        }
        guard longest > 0, let first = text.first, let last = text.last else { return nil }
        let ticks = [UInt16](repeating: 0x60, count: longest + 1)
        let pad: [UInt16] = first == 0x60 || last == 0x60 ? [0x20] : []
        return (ticks + pad, pad + ticks)
    }

    private static func starred(_ m: Mark, _ delim: [UInt16], _ options: WriteOptions) -> [UInt16] {
        guard m.kind == .strong || m.kind == .em, delim.first == 0x5F else { return delim }
        switch options.stars {
        case .none: return delim
        case .newMarks: return m.id >= Mark.firstNewID ? delim.map { _ in 0x2A } : delim
        case .all: return delim.map { _ in 0x2A }
        }
    }

    private static let inlineSpecials = Set("\\`*_[]<>&~|".utf16)
    private static let blockSpecials = Set("#-+>.)=!:".utf16)

    private static func needsEscape(_ atoms: [Atom], _ i: Int, _ mode: WriteOptions.Escape) -> Bool {
        let unit = atoms[i].unit
        switch mode {
        case .none: return false
        case .inline: return inlineSpecials.contains(unit)
        case .block: return inlineSpecials.contains(unit) || blockSpecials.contains(unit)
        }
    }
}

public enum Outline {
    /// A compact description of parsed structure. It's both what scenarios assert
    /// on and what the editor compares to verify an edit.
    public static func of(_ root: Block, replacing old: Block? = nil, with atoms: [Atom] = []) -> String {
        describe(root, old, atoms)
    }

    public static func of(single block: Block) -> String { describe(block, nil, []) }

    private static func describe(_ b: Block, _ old: Block?, _ atoms: [Atom]) -> String {
        func kids() -> String { b.children.map { describe($0, old, atoms) }.joined(separator: ",") }
        func text() -> String { inline(b === old ? atoms : b.atoms, opaque: b.opaque, b: b) }
        switch b.kind {
        case .document: return kids()
        case .paragraph: return "p[\(text())]"
        case .heading(let n): return "h\(n)[\(text())]"
        case .quote: return "q[\(kids())]"
        case .list(let ordered, let start): return ordered ? "ol\(start)[\(kids())]" : "ul[\(kids())]"
        case .item(let checked):
            let box = checked.map { $0 ? "(x)" : "( )" } ?? ""
            return "li\(box)[\(kids())]"
        case .code(let info): return "code(\(info))[\(text())]"
        case .html: return "html"
        case .rule: return "hr"
        case .table: return "t[\(kids())]"
        case .row: return "r[\(kids())]"
        case .cell: return "c[\(text())]"
        }
    }

    private static func inline(_ atoms: [Atom], opaque: Bool, b: Block) -> String {
        if opaque { return "<opaque>" }
        var trimmed = atoms
        func edge(_ a: Atom) -> Bool { a.kind == .ignored || (a.kind == .text && (a.unit == 0x20 || a.unit == 0x09)) }
        if case .code = b.kind {} else {
            while let last = trimmed.last, edge(last) { trimmed.removeLast() }
            while let first = trimmed.first, edge(first) { trimmed.removeFirst() }
        }
        /// Bare URLs are linkified from their text, so they aren't structure:
        /// typing can start, extend, or end one. An autolink's target is its text.
        func tag(_ m: Mark) -> String? {
            guard case .link(let dest) = m.kind else { return m.kind.name }
            if m.open.isEmpty { return nil }
            return m.open == [0x3C] ? "a=auto" : "a=\(dest)"
        }
        var units: [UInt16] = []
        var stack: [String] = []
        for a in trimmed {
            let tags = a.marks.compactMap(tag)
            var common = 0
            while common < stack.count, common < tags.count, stack[common] == tags[common] { common += 1 }
            func close() { units += Array("</\(stack.removeLast().prefix { $0 != "=" })>".utf16) }
            while stack.count > common { close() }
            for t in tags[common...] {
                units += Array("<\(t)>".utf16)
                stack.append(t)
            }
            switch a.kind {
            case .softBreak: units += Array("⏎".utf16)
            case .hardBreak: units += Array("⇩".utf16)
            case .object: units += Array("▣".utf16)
            case .text, .ignored: units.append(a.unit)
            }
        }
        while let t = stack.popLast() { units += Array("</\(t.prefix { $0 != "=" })>".utf16) }
        return String(decoding: units, as: UTF16.self)
    }
}
