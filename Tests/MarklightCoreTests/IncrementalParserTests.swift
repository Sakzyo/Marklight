import Foundation
import Testing
@testable import MarklightCore

// Mark IDs are local to a parse. Compare grouping by a bijection between IDs in
// each leaf, and compare delimiter spelling and link destinations independently.
private struct MarkGroups {
    var forward: [Int: Int] = [:]
    var backward: [Int: Int] = [:]

    mutating func match(_ a: Mark, _ b: Mark) -> Bool {
        guard a.kind == b.kind, a.open == b.open, a.close == b.close else { return false }
        if case .link(let left) = a.kind, case .link(let right) = b.kind,
           !left.utf8.elementsEqual(right.utf8) { return false }
        if let id = forward[a.id] { return id == b.id }
        guard backward[b.id] == nil else { return false }
        forward[a.id] = b.id
        backward[b.id] = a.id
        return true
    }

    mutating func match(_ a: Inline, _ b: Inline) -> Bool {
        guard a.range == b.range, a.atoms == b.atoms, a.children.count == b.children.count else { return false }
        switch (a.kind, b.kind) {
        case (.run, .run): break
        case let (.mark(x), .mark(y)): guard match(x, y) else { return false }
        case let (.image(x, altX), .image(y, altY)):
            guard x.utf8.elementsEqual(y.utf8), altX.utf8.elementsEqual(altY.utf8) else { return false }
        case let (.html(x), .html(y)): guard x.utf8.elementsEqual(y.utf8) else { return false }
        default: return false
        }
        return zip(a.children, b.children).allSatisfy { match($0, $1) }
    }
}

/// Independent of the production idle audit. Report the first block and field
/// to diverge, so the seed and edit in the error identify a reproducible case.
private func difference(_ a: Block, _ b: Block) -> String? {
    guard a.kind == b.kind else { return "kind \(a.kind) vs \(b.kind)" }
    if case .code(let x) = a.kind, case .code(let y) = b.kind, !x.utf8.elementsEqual(y.utf8) { return "code info" }
    guard a.range == b.range else { return "range \(a.range) vs \(b.range)" }
    guard a.content == b.content else { return "content \(a.content) vs \(b.content)" }
    guard a.isOpaque == b.isOpaque, a.rawHTML.utf8.elementsEqual(b.rawHTML.utf8),
          a.columnAlignments == b.columnAlignments else { return "block metadata" }
    guard a.atoms.count == b.atoms.count else { return "atom count \(a.atoms.count) vs \(b.atoms.count)" }
    var groups = MarkGroups()
    for (i, (x, y)) in zip(a.atoms, b.atoms).enumerated() {
        guard x.kind == y.kind, x.unit == y.unit, x.range == y.range,
              x.marks.count == y.marks.count, zip(x.marks, y.marks).allSatisfy({ groups.match($0, $1) }) else {
            return "atom \(i) at \(x.range) vs \(y.range)"
        }
    }
    guard a.inlines.count == b.inlines.count,
          zip(a.inlines, b.inlines).allSatisfy({ groups.match($0, $1) }) else { return "inlines" }
    guard a.children.count == b.children.count else { return "child count" }
    for (i, (x, y)) in zip(a.children, b.children).enumerated() {
        guard x.parent === a else { return "child \(i) lost parent" }
        if let diff = difference(x, y) { return "child \(i): \(diff)" }
    }
    return nil
}

private struct ParseMismatch: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func checkAgainstFullParse(_ incremental: IncrementalDocument, expected: [UInt16], context: String) throws {
    guard incremental.units == expected else { throw ParseMismatch("\(context): wrong source units") }
    let full = ParsedDocument(units: expected)
    guard incremental.blockCount == full.root.children.count else {
        throw ParseMismatch("\(context): \(incremental.blockCount) vs \(full.root.children.count) blocks")
    }
    for (i, expectedBlock) in full.root.children.enumerated() {
        if let diff = difference(incremental.block(at: i), expectedBlock) {
            throw ParseMismatch("\(context), block \(i): \(diff)")
        }
    }
}

// LCG with a fixed mapping to indices so seeds replay independently of Swift's
// random(in:) implementation or the order in which parameterized tests run.
private struct ParserSeed {
    var state: UInt64
    mutating func pick(_ count: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(count))
    }
}

@Suite("Incremental parser")
struct IncrementalParserTests {
    @Test("Typing in a paragraph uses the local parse and preserves every later source range")
    func middleOfLargeDocument() throws {
        let paragraphs = (0..<400).map { "Paragraph \($0) with __words__ and e\u{301}." }
        let text = paragraphs.joined(separator: "\n\n")
        var expected = Array(text.utf16)
        var doc = IncrementalDocument(units: expected)
        let at = (text as NSString).range(of: "Paragraph 200").location + 3
        for word in ["x", "文", "🦉"] {
            let patch = Patch(range: at..<at, replacement: Array(word.utf16), origin: .rendered)
            doc = doc.applying(patch)
            expected.replaceSubrange(patch.range, with: patch.replacement)
            if word == "x" { #expect(!doc.usedFullParse) }
            try checkAgainstFullParse(doc, expected: expected, context: "typing \(word) at \(at)")
        }
    }

    @Test("A local reparse keeps marks in different blocks distinct")
    func markIdentity() throws {
        let text = "*a*\n\n*b*\n\n*c*\n\n*d*\n\n*e*"
        let at = (text as NSString).range(of: "d").location
        let doc = IncrementalDocument(units: Array(text.utf16)).applying(Patch(range: at..<at, replacement: [120], origin: .rendered))
        try #require(!doc.usedFullParse)
        let marks = try (0..<doc.blockCount).map { index in try #require(doc.block(at: index).atoms.first?.marks.first) }
        #expect(Set(marks).count == doc.blockCount)
    }

    @Test("Edits that cross Markdown context boundaries match a full parse")
    func contextChanges() throws {
        let gap = (0..<12).map { "Unrelated \($0)\n\n" }.joined()
        let cases = [
            ("[name][ref]\n\n" + gap + "[ref]: /old\n", "/old", "/new"),
            ("[name][ref]\n\n" + gap + "x[ref]: /new\n", "x[ref]", "[ref]"),
            ("[name][ref]\n\n" + gap + "[ref]: /old\n", "name", "说明"),
            ("---\nkey: value\n---\n\n" + gap + "---\nend", "key: value\n---", "key: value"),
            ("lead\n\n---\n\n" + gap + "---\nend", "lead", "head"),
            ("top\n\nraw\n\n" + gap + "```\nafter", "raw", "```swift"),
            ("heading\r\n===\r\n\r\nbody\r\n", "===", " ="),
            ("lead\r\n\r\n> one\r\nlazy\r\n\r\nnext", "lazy", "> two"),
            ("lead\n\n- a\n\nlazy\n\nnext", "\n\nlazy", "\n  lazy"),
            ("line\r\n\r\nlast\n\nmixed\rnext", "\r\n\r\n", "\r"),
            ("a\n\n| header |\n| --- |\n| cell |\n\nz", "---", "x"),
            ("a\n\n<div>\nhtml\n\nnext\n\nz", "<div>", "<!--"),
            ("\u{feff}a\n\nsecond\n", "\u{feff}a", ""),
        ]
        for (text, needle, replacement) in cases {
            let units = Array(text.utf16)
            let match = (text as NSString).range(of: needle)
            let patch = Patch(range: match.location..<NSMaxRange(match), replacement: Array(replacement.utf16), origin: .rendered)
            let doc = IncrementalDocument(units: units).applying(patch)
            var expected = units
            expected.replaceSubrange(patch.range, with: patch.replacement)
            try checkAgainstFullParse(doc, expected: expected, context: "\(needle.debugDescription) → \(replacement.debugDescription)")
        }
    }

    @Test("Seeded patch sequences match a fresh full parse after every edit", arguments: Fixtures.all)
    func fuzz(name: String) throws {
        var expected = TextCodec.decode(try Fixtures.data(name)).units
        var doc = IncrementalDocument(units: expected)
        let seed = name.utf8.reduce(UInt64(73021)) { $0 &* 31 &+ UInt64($1) }
        var random = ParserSeed(state: seed)
        let pieces = ["x", " ", "中文", "🦉", "e\u{301}", "&amp;", "\\*", "**", "`", "[ref]", ":", "\n", "\r\n", "~~~", ""]
        let steps = ProcessInfo.processInfo.environment["MARKLIGHT_LARGE_FUZZ"] == "1" ? 200 : 8
        for step in 0..<steps {
            func boundary(_ i: Int) -> Int {
                i < expected.count && (0xDC00..<0xE000).contains(expected[i]) ? i + 1 : i
            }
            let start = boundary(random.pick(expected.count + 1))
            let length = random.pick(1 + min(5, expected.count - start))
            let end = boundary(start + length)
            let insert = pieces[random.pick(pieces.count)]
            let patch = Patch(range: start..<end, replacement: Array(insert.utf16), origin: .rendered)
            doc = doc.applying(patch)
            expected.replaceSubrange(patch.range, with: patch.replacement)
            try checkAgainstFullParse(doc, expected: expected, context: "\(name) seed \(seed) step \(step), \(patch.range) → \(insert.debugDescription)")
        }
    }
}
