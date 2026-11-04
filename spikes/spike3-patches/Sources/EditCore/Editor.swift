import Foundation

public enum Origin { case source, rendered, command }

/// `range` is in UTF-16 units against the text before the patch (`docs/contracts.md`).
public struct Patch {
    public let range: Range<Int>
    public let replacement: [UInt16]
    public let origin: Origin

    /// The smallest single replacement turning `old` into `new`.
    public static func minimal(from old: [UInt16], to new: [UInt16], origin: Origin) -> Patch {
        var p = 0
        let maxPrefix = min(old.count, new.count)
        while p < maxPrefix, old[p] == new[p] { p += 1 }
        if p > 0, (0xDC00..<0xE000).contains(old[safe: p] ?? 0) || (0xDC00..<0xE000).contains(new[safe: p] ?? 0) { p -= 1 }
        var s = 0
        let maxSuffix = maxPrefix - p
        while s < maxSuffix, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        if s > 0, (0xDC00..<0xE000).contains(old[old.count - s]) { s -= 1 }
        return Patch(range: p..<(old.count - s), replacement: Array(new[p..<(new.count - s)]), origin: origin)
    }
}

public struct PasteRun {
    public var text: String
    public var marks: [String] // "strong", "em", "strike", "code"
    public var href: String?
    public init(_ text: String, marks: [String] = [], href: String? = nil) {
        self.text = text
        self.marks = marks
        self.href = href
    }
}

public struct PasteBlock {
    public enum Kind: Equatable { case paragraph, heading(Int), bullet, ordered, quote, code }
    public var kind: Kind
    public var runs: [PasteRun]
    public init(_ kind: Kind, _ runs: [PasteRun]) {
        self.kind = kind
        self.runs = runs
    }
}

public enum MarkKind: String { case strong, em, strike, code }

public enum Command {
    case insert(String, Range<Int>)
    /// Backspace or forward delete. A non-empty range comes from the browser's
    /// `getTargetRanges`, which handles graphemes, words, and lines.
    case delete(Range<Int>, backward: Bool)
    case enter(Range<Int>)
    case lineBreak(Range<Int>)
    case toggle(MarkKind, Range<Int>)
    case heading(Int, at: Int)
    case checkbox(at: Int)
    case pastePlain(String, Range<Int>)
    case pasteRich([PasteBlock], Range<Int>)
}

public struct Outcome {
    public enum Path: String { case leaf, block, noop, refused }
    public let patch: Patch?
    public let caret: Int
    public let path: Path
    public let note: String
    public let reparses: Int
}

public final class Editor {
    public private(set) var units: [UInt16]
    public private(set) var doc: DocModel
    /// Offset of a paragraph that exists only as a caret position. Markdown has
    /// no empty paragraphs, so this is view state, never document text.
    public private(set) var pending: Int?
    var pendingOverride: Int?
    private var undoStack: [Patch] = []

    var caret = 0
    var path = Outcome.Path.noop
    var note = ""
    var reparses = 0
    var nextMark = Mark.firstNewID

    public var text: String { String(decoding: units, as: UTF16.self) }

    public init(text: String) {
        units = Array(text.utf16)
        doc = DocModel(units: units)
    }

    @discardableResult
    public func perform(_ command: Command) -> Outcome {
        let before = units
        let beforeDoc = doc
        let wasPending = pending
        pending = nil
        pendingOverride = nil
        path = .noop
        note = ""
        reparses = 0
        do {
            try run(command, wasPending: wasPending)
            pending = pendingOverride
            if path == .block, units != before {
                try verifyBlockEdit(beforeDoc, before, command)
            }
        } catch let error as Refusal {
            path = .refused
            note = error.reason
            commit(before, caret: start(of: command))
            pending = wasPending
        } catch {
            path = .refused
            note = "\(error)"
        }
        guard units != before else {
            return Outcome(patch: nil, caret: caret, path: path, note: note, reparses: reparses)
        }
        let patch = Patch.minimal(from: before, to: units, origin: .rendered)
        let inverse = Patch(range: patch.range.lowerBound..<(patch.range.lowerBound + patch.replacement.count),
                            replacement: Array(before[patch.range]), origin: .command)
        undoStack.append(inverse)
        return Outcome(patch: patch, caret: caret, path: path, note: note, reparses: reparses)
    }

    /// Block edits rewrite source directly, so check them the same way leaf edits
    /// are checked: everything outside the patch parses as before, and nothing
    /// that should survive went missing.
    private func verifyBlockEdit(_ old: DocModel, _ before: [UInt16], _ command: Command) throws {
        let patch = Patch.minimal(from: before, to: units, origin: .rendered)
        let a = old.root.children, b = doc.root.children
        // Diffing can slide an insert past a newline, so a block only counts as
        // outside the patch if real separation lies between them.
        func separated(_ gap: Range<Int>) -> Bool {
            let text = before[gap]
            let breaks = text.filter { $0 == 0x0A }.count + text.filter { $0 == 0x0D }.count - zip(text, text.dropFirst()).filter { $0 == 0x0D && $1 == 0x0A }.count
            return breaks >= 2 || text.contains { !$0.isLineBreak && !$0.isSpaceOrTab }
        }
        let head = a.prefix { $0.range.upperBound < patch.range.lowerBound && separated($0.range.upperBound..<patch.range.lowerBound) }
        for (i, block) in head.enumerated() {
            guard i < b.count, Outline.of(single: block) == Outline.of(single: b[i]) else { throw Refusal("edit would change an earlier block") }
        }
        let tail = a.reversed().prefix { $0.range.lowerBound > patch.range.upperBound && separated(patch.range.upperBound..<$0.range.lowerBound) }
        for (i, block) in tail.enumerated() {
            guard i < b.count, Outline.of(single: block) == Outline.of(single: b[b.count - 1 - i]) else { throw Refusal("edit would change a later block") }
        }
        func unanchored(_ d: DocModel) -> Int { d.root.allLeaves().filter { $0.opaque }.count }
        guard unanchored(doc) <= unanchored(old) else { throw Refusal("edit would leave a block that can't be mapped") }
        var keepsText = false
        switch command {
        case .enter(let r): keepsText = r.isEmpty
        case .delete(let r, _): keepsText = r.isEmpty
        default: break
        }
        func words(_ d: DocModel) -> String {
            d.root.allLeaves().map { Editor.plain($0.atoms) }.joined().filter { !$0.isWhitespace }
        }
        if keepsText, words(old) != words(doc) { throw Refusal("edit would lose text") }
    }

    public func undo() {
        guard let p = undoStack.popLast() else { return }
        var u = units
        u.replaceSubrange(p.range, with: p.replacement)
        commit(u, caret: p.range.lowerBound + p.replacement.count)
    }

    private func start(of command: Command) -> Int {
        switch command {
        case .insert(_, let r), .delete(let r, _), .enter(let r), .lineBreak(let r), .toggle(_, let r),
             .pastePlain(_, let r), .pasteRich(_, let r):
            return r.lowerBound
        case .heading(_, let at), .checkbox(let at):
            return at
        }
    }

    func commit(_ new: [UInt16], caret: Int, doc: DocModel? = nil) {
        units = new
        self.doc = doc ?? DocModel(units: new)
        self.caret = caret
    }

    private func run(_ command: Command, wasPending: Int?) throws {
        switch command {
        case .insert(let text, let range): try insert(text, range, pending: wasPending)
        case .delete(let range, let backward): try delete(range, backward: backward, pending: wasPending)
        case .enter(let range): try enter(range, pending: wasPending)
        case .lineBreak(let range): try lineBreak(range)
        case .toggle(let kind, let range): try toggle(kind, range)
        case .heading(let level, let at): try setHeading(level, at: at)
        case .checkbox(let at): try toggleCheckbox(at: at)
        case .pastePlain(let text, let range): try pastePlain(text, range, pending: wasPending)
        case .pasteRich(let blocks, let range): try pasteRich(blocks, range, pending: wasPending)
        }
    }

    // MARK: - Locating

    func leaf(at offset: Int) -> Block? {
        doc.root.allLeaves().first { $0.content.lowerBound <= offset && offset <= $0.content.upperBound }
    }

    func atomIndex(_ leaf: Block, _ offset: Int) -> Int {
        var i = 0
        let atoms = leaf.atoms
        while i < atoms.count {
            guard let r = atoms[i].range else { i += 1; continue }
            if r.upperBound <= offset { i += 1; continue }
            if r.lowerBound >= offset { return i }
            // Inside an escape, entity, or break: snap past it.
            while i < atoms.count, atoms[i].range == r { i += 1 }
            return i
        }
        return atoms.count
    }

    func marks(at offset: Int, in leaf: Block, index i: Int) -> [Mark] {
        if i > 0, let r = leaf.atoms[i - 1].range, r.upperBound == offset { return leaf.atoms[i - 1].marks }
        if i < leaf.atoms.count, let r = leaf.atoms[i].range, r.lowerBound == offset { return leaf.atoms[i].marks }
        return []
    }

    func textAtoms(_ text: String, marks: [Mark]) -> [Atom] {
        text.utf16.map { Atom(kind: .text, unit: $0, marks: marks) }
    }

    func eol(at offset: Int) -> [UInt16] {
        var i = min(offset, units.count) - 1
        while i >= 0 {
            if units[i] == 0x0A { return i > 0 && units[i - 1] == 0x0D ? [0x0D, 0x0A] : [0x0A] }
            if units[i] == 0x0D { return [0x0D] }
            i -= 1
        }
        i = offset
        while i < units.count {
            if units[i] == 0x0D { return units[safe: i + 1] == 0x0A ? [0x0D, 0x0A] : [0x0D] }
            if units[i] == 0x0A { return [0x0A] }
            i += 1
        }
        return [0x0A]
    }

    func lineStart(_ offset: Int) -> Int {
        var i = offset
        while i > 0, !units[i - 1].isLineBreak { i -= 1 }
        return i
    }

    func lineEnd(_ offset: Int) -> Int {
        var i = offset
        while i < units.count, !units[i].isLineBreak { i += 1 }
        return i
    }

    /// Width of a list marker plus the spaces after it.
    func markerWidth(_ item: Block) -> Int {
        var i = item.range.lowerBound
        let lo = i
        while let u = units[safe: i], (0x30...0x39).contains(u) { i += 1 }
        i += 1 // the bullet, or the . or ) after the digits
        let contentStart = i
        while let u = units[safe: i], u == 0x20 { i += 1 }
        let spaces = i - contentStart
        if units[safe: i] == nil || units[i].isLineBreak || spaces == 0 || spaces > 4 { return contentStart - lo + 1 }
        return i - lo
    }

    /// The prefix a new line needs to stay inside `block`'s containers.
    func linePrefix(_ block: Block) -> [UInt16] {
        var chain: [Block] = []
        var b: Block? = block.parent
        while let c = b { chain.insert(c, at: 0); b = c.parent }
        return prefix(through: chain)
    }

    private func prefix(through chain: [Block]) -> [UInt16] {
        var out: [UInt16] = []
        for c in chain {
            switch c.kind {
            case .quote:
                out += [0x3E, 0x20]
            case .item:
                let col = c.range.lowerBound - lineStart(c.range.lowerBound)
                out += [UInt16](repeating: 0x20, count: max(0, col - out.count)) // the item's own indent
                out += [UInt16](repeating: 0x20, count: markerWidth(c))
            default:
                break
            }
        }
        return out
    }

    func blank(_ prefix: [UInt16]) -> [UInt16] {
        var p = prefix
        while p.last == 0x20 { p.removeLast() }
        return p
    }

    func emptyItem(at offset: Int) -> Block? {
        func walk(_ b: Block) -> Block? {
            if case .item = b.kind, b.children.isEmpty, b.range.lowerBound <= offset, offset <= lineEnd(b.range.lowerBound) { return b }
            for c in b.children { if let r = walk(c) { return r } }
            return nil
        }
        return walk(doc.root)
    }

    func replacing(_ range: Range<Int>, with new: [UInt16]) -> [UInt16] {
        var u = units
        u.replaceSubrange(range, with: new)
        return u
    }

    // MARK: - Leaf edits

    struct Attempt {
        var escape: WriteOptions.Escape = .none
        var reescape = false
        var stars = WriteOptions.Stars.none
        var widen = false
    }

    static let attempts = [
        Attempt(), Attempt(escape: .inline), Attempt(widen: true), Attempt(escape: .block),
        Attempt(escape: .inline, stars: .newMarks), Attempt(escape: .inline, stars: .all),
        Attempt(escape: .block, reescape: true),
    ]

    /// Replace a leaf's atoms: serialize, re-parse the whole document, and accept
    /// only if the outcome has exactly the expected structure.
    func editLeaf(_ leaf: Block, _ newAtoms: [Atom], caret index: Int) throws {
        guard !leaf.opaque else { throw Refusal("leaf could not be anchored") }
        // Normalizing moves whitespace out of marks but never adds or removes atoms.
        var atoms = Serializer.normalize(newAtoms)
        var index = index
        // Leading whitespace in a paragraph is invisible and shouldn't be written.
        if case .paragraph = leaf.kind {
            while let first = atoms.first, first.kind == .text, first.isSpace {
                atoms.removeFirst()
                index = max(0, index - 1)
            }
        }
        let expected = Outline.of(doc.root, replacing: leaf, with: atoms)
        var options = WriteOptions()
        options.eol = eol(at: leaf.content.lowerBound)
        options.linePrefix = linePrefix(leaf)
        options.explicitLinks = changedLinks(leaf.atoms, atoms)
        if case .cell = leaf.kind { options.inCell = true }
        for attempt in Editor.attempts {
            options.widenCode = attempt.widen
            options.escape = attempt.escape
            options.reescapeExisting = attempt.reescape
            options.stars = attempt.stars
            var at = 0
            let written = Serializer.write(atoms, source: units, options: options, caret: index, caretOffset: &at)
            let candidate = replacing(leaf.content, with: written)
            let parsed = DocModel(units: candidate)
            reparses += 1
            if Outline.of(parsed.root) == expected {
                commit(candidate, caret: leaf.content.lowerBound + at, doc: parsed)
                path = .leaf
                return
            }
        }
        throw Refusal("no serialization reproduces the expected structure")
    }

    /// Links whose text differs after the edit.
    private func changedLinks(_ old: [Atom], _ new: [Atom]) -> Set<Mark> {
        func texts(_ atoms: [Atom]) -> [Mark: [UInt16]] {
            var out: [Mark: [UInt16]] = [:]
            for a in atoms {
                for m in a.marks where m.explicitClose != nil { out[m, default: []].append(a.unit) }
            }
            return out
        }
        let a = texts(old), b = texts(new)
        return Set(a.keys.filter { a[$0] != b[$0] })
    }

    func insert(_ text: String, _ range: Range<Int>, pending: Int?) throws {
        guard !text.isEmpty else { return }
        if range.isEmpty, leaf(at: range.lowerBound) == nil || range.lowerBound == pending {
            return try insertInGap(text, at: range.lowerBound, pending: pending)
        }
        guard let target = leaf(at: range.lowerBound) else { throw Refusal("no text block at \(range.lowerBound)") }
        guard range.upperBound <= target.content.upperBound else {
            try deleteAcross(range)
            return try insert(text, caret..<caret, pending: nil)
        }
        if case .code = target.kind { return try editCode(target, range, text) }
        let i = atomIndex(target, range.lowerBound)
        let j = atomIndex(target, range.upperBound)
        if i == 0, text.allSatisfy({ $0 == " " || $0 == "\t" }), target.kind == .paragraph {
            caret = range.lowerBound
            return // leading whitespace would be invisible
        }
        let marks = !range.isEmpty && i < target.atoms.count ? target.atoms[i].marks : self.marks(at: range.lowerBound, in: target, index: i)
        let new = textAtoms(text, marks: marks)
        do {
            try editLeaf(target, Array(target.atoms[..<i]) + new + Array(target.atoms[j...]), caret: i + new.count)
        } catch let refusal as Refusal {
            // `**When:**x` can't close: a delimiter after punctuation needs a space or
            // punctuation next. Better to extend the mark than to drop the keystroke.
            guard range.isEmpty, marks.isEmpty, i > 0, !target.atoms[i - 1].marks.isEmpty else { throw refusal }
            let extended = textAtoms(text, marks: target.atoms[i - 1].marks)
            try editLeaf(target, Array(target.atoms[..<i]) + extended + Array(target.atoms[j...]), caret: i + extended.count)
        }
    }

    /// Typing where only a caret exists: a pending paragraph or an empty list item.
    private func insertInGap(_ text: String, at offset: Int, pending: Int?) throws {
        guard offset == pending || emptyItem(at: offset) != nil else { throw Refusal("nothing editable at \(offset)") }
        var options = WriteOptions()
        let new = textAtoms(text, marks: [])
        for escape in [WriteOptions.Escape.none, .inline, .block] {
            options.escape = escape
            let written = Serializer.write(new, source: units, options: options)
            let candidate = replacing(offset..<offset, with: written)
            let parsed = DocModel(units: candidate)
            reparses += 1
            let leaves = parsed.root.allLeaves()
            if let l = leaves.first(where: { $0.content.lowerBound == offset }),
               Editor.plain(l.atoms) == text {
                commit(candidate, caret: offset + written.count, doc: parsed)
                path = .block
                return
            }
        }
        throw Refusal("text would not parse as a paragraph here")
    }

    public static func plainText(_ leaf: Block) -> String { plain(leaf.atoms) }

    static func plain(_ atoms: [Atom]) -> String {
        String(decoding: atoms.filter { $0.kind == .text || $0.kind == .ignored }.map { $0.unit }, as: UTF16.self)
    }

    func editCode(_ code: Block, _ range: Range<Int>, _ text: String) throws {
        let candidate = replacing(range, with: Array(text.utf16))
        let parsed = DocModel(units: candidate)
        reparses += 1
        let same = parsed.root.allLeaves().count == doc.root.allLeaves().count
        let reparsed = parsed.root.allLeaves().first { $0.range.lowerBound == code.range.lowerBound }
        guard same, let reparsed, case .code = reparsed.kind else { throw Refusal("edit would break the code fence") }
        // Every other character has to come through, with this edit's change.
        func visible(_ s: some Sequence<UInt16>) -> Int { s.filter { $0 != 0x20 && $0 != 0x09 && !$0.isLineBreak }.count }
        func count(_ b: Block) -> Int { visible(b.atoms.filter { $0.kind == .text }.map { $0.unit }) }
        func total(_ d: DocModel) -> Int { d.root.allLeaves().reduce(0) { $0 + count($1) } }
        let delta = visible(text.utf16) - visible(units[range])
        guard total(parsed) == total(doc) + delta, count(reparsed) == count(code) + delta else { throw Refusal("edit would break the code block") }
        commit(candidate, caret: range.lowerBound + text.utf16.count, doc: parsed)
        path = .leaf
    }

    func delete(_ range: Range<Int>, backward: Bool, pending: Int?) throws {
        if range.isEmpty {
            let offset = range.lowerBound
            if let target = leaf(at: offset), offset != pending {
                let i = atomIndex(target, offset)
                if backward, i > 0 {
                    return try deleteGrapheme(target, before: i)
                }
                if !backward, i < target.atoms.count {
                    return try deleteGrapheme(target, after: i)
                }
                return backward ? try backspaceAtStart(target) : try deleteAtEnd(target)
            }
            if let item = emptyItem(at: offset) { return try exitItem(item) }
            if offset == pending { return try removePending(offset, backward: backward) }
            throw Refusal("nothing to delete at \(offset)")
        }
        guard let target = leaf(at: range.lowerBound), range.upperBound <= target.content.upperBound else {
            return try deleteAcross(range)
        }
        if case .code = target.kind { return try editCode(target, range, "") }
        let i = atomIndex(target, range.lowerBound)
        let j = atomIndex(target, range.upperBound)
        try removeAtoms(target, i, j)
    }

    private func removeAtoms(_ target: Block, _ i: Int, _ j: Int) throws {
        let rest = Array(target.atoms[..<i]) + Array(target.atoms[j...])
        if rest.isEmpty, target.kind == .paragraph {
            // A paragraph with no text can't exist in Markdown.
            let at = target.content.lowerBound
            commit(replacing(target.content, with: []), caret: at)
            pendingOverride = at
            path = .block
            return
        }
        try editLeaf(target, rest, caret: i)
    }

    private func graphemes(_ atoms: [Atom]) -> [Range<Int>] {
        // Objects and breaks are one atom each, standing in for one unit.
        let units = atoms.map { $0.kind == .text || $0.kind == .ignored ? $0.unit : 0xFFFC }
        let s = String(decoding: units, as: UTF16.self)
        var out: [Range<Int>] = []
        var at = 0
        for ch in s {
            let n = ch.utf16.count
            out.append(at..<at + n)
            at += n
        }
        return out
    }

    private func deleteGrapheme(_ target: Block, before i: Int) throws {
        let g = graphemes(target.atoms).last { $0.lowerBound < i } ?? (i - 1)..<i
        if case .code = target.kind { return try deleteCode(target, g.lowerBound, i) }
        try removeAtoms(target, g.lowerBound, i)
    }

    private func deleteGrapheme(_ target: Block, after i: Int) throws {
        let g = graphemes(target.atoms).first { $0.upperBound > i } ?? i..<(i + 1)
        if case .code = target.kind { return try deleteCode(target, i, g.upperBound) }
        try removeAtoms(target, i, g.upperBound)
    }

    private func deleteCode(_ code: Block, _ i: Int, _ j: Int) throws {
        let lo = code.atoms[i].range!.lowerBound
        let hi = j < code.atoms.count ? code.atoms[j].range!.lowerBound : code.content.upperBound
        try editCode(code, lo..<hi, "")
    }

    func toggle(_ kind: MarkKind, _ range: Range<Int>) throws {
        guard !range.isEmpty else { throw Refusal("nothing selected") }
        guard let target = leaf(at: range.lowerBound), range.upperBound <= target.content.upperBound else {
            throw Refusal("selection spans blocks")
        }
        if case .code = target.kind { throw Refusal("no marks in code blocks") }
        var i = atomIndex(target, range.lowerBound)
        var j = atomIndex(target, range.upperBound)
        while i < j, target.atoms[i].isSpace { i += 1 }
        while j > i, target.atoms[j - 1].isSpace { j -= 1 }
        guard i < j else { throw Refusal("selection is only whitespace") }

        let wanted: Mark.Kind = kind == .strong ? .strong : kind == .em ? .em : kind == .strike ? .strike : .code
        var atoms = target.atoms
        let body = i..<j
        let textual = body.filter { atoms[$0].kind == .text && !atoms[$0].isSpace }
        let remove = !textual.isEmpty && textual.allSatisfy { k in atoms[k].marks.contains { $0.kind == wanted } }

        if remove {
            for k in body {
                atoms[k].marks.removeAll { $0.kind == wanted }
                if wanted == .code { atoms[k].range = nil } // now text, so it may need escaping
            }
        } else if wanted == .code {
            let text = body.map { atoms[$0].unit }
            var longest = 0, run = 0
            for u in text { run = u == 0x60 ? run + 1 : 0; longest = max(longest, run) }
            let ticks = [UInt16](repeating: 0x60, count: longest + 1)
            nextMark += 1
            let edge: [UInt16] = text.first == 0x60 || text.last == 0x60 ? [0x20] : []
            let mark = Mark(kind: .code, id: nextMark, open: ticks + edge, close: edge + ticks)
            for k in body {
                atoms[k].marks = [mark]
                if atoms[k].range?.count != 1 { atoms[k].range = nil }
            }
        } else {
            let neighbour = (i > 0 ? atoms[i - 1].marks.first { $0.kind == wanted } : nil)
                ?? (j < atoms.count ? atoms[j].marks.first { $0.kind == wanted } : nil)
            let mark = neighbour ?? newMark(wanted)
            // Nest inside marks that reach past the selection, around those inside it.
            let crossing = Set((i > 0 ? atoms[i - 1].marks : []) + (j < atoms.count ? atoms[j].marks : []))
            for k in body {
                atoms[k].marks.removeAll { $0.kind == wanted }
                let at = atoms[k].marks.prefix { crossing.contains($0) }.count
                atoms[k].marks.insert(mark, at: at)
            }
            // Touching runs of the same kind must become one run.
            for k in atoms.indices.dropFirst() {
                if let left = atoms[k - 1].marks.first(where: { $0.kind == wanted }),
                   let at = atoms[k].marks.firstIndex(where: { $0.kind == wanted }), atoms[k].marks[at] != left {
                    atoms[k].marks[at] = left
                }
            }
        }
        try editLeaf(target, atoms, caret: j)
    }

    func newMark(_ kind: Mark.Kind) -> Mark {
        nextMark += 1
        let delim: [UInt16] = {
            switch kind {
            case .strong: return Array(style.strong.utf16)
            case .em: return Array(style.em.utf16)
            case .strike: return [0x7E, 0x7E]
            default: return []
            }
        }()
        return Mark(kind: kind, id: nextMark, open: delim, close: delim)
    }

    /// Per-file style: follow what the document already uses (`docs/plan.md` 2.2).
    var style: (strong: String, em: String) {
        var strongStars = 0, strongUnders = 0, emStars = 0, emUnders = 0
        for leaf in doc.root.allLeaves() {
            var seen = Set<Int>()
            for atom in leaf.atoms {
                for m in atom.marks where seen.insert(m.id).inserted {
                    let first = m.open.first
                    if m.kind == .strong { if first == 0x5F { strongUnders += 1 } else { strongStars += 1 } }
                    if m.kind == .em { if first == 0x5F { emUnders += 1 } else { emStars += 1 } }
                }
            }
        }
        return (strongUnders > strongStars ? "__" : "**", emUnders > emStars ? "_" : "*")
    }

    func toggleCheckbox(at offset: Int) throws {
        func find(_ b: Block) -> Block? {
            if case .item(let c) = b.kind, c != nil, b.range.contains(offset) || b.range.upperBound == offset {
                for child in b.children { if let r = find(child) { return r } }
                return b
            }
            for child in b.children { if let r = find(child) { return r } }
            return nil
        }
        guard let item = find(doc.root), case .item(let checked?) = item.kind else { throw Refusal("no task item") }
        let box = item.range.lowerBound + markerWidth(item)
        guard units[safe: box] == 0x5B, units[safe: box + 2] == 0x5D else { throw Refusal("no checkbox source") }
        let new: UInt16 = checked ? 0x20 : 0x78
        commit(replacing((box + 1)..<(box + 2), with: [new]), caret: offset)
        path = .leaf
    }
}

public struct Refusal: Error {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}
