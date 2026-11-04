import Foundation
import Testing
@testable import MarklightCore

private func parse(_ s: String) -> ParsedDocument { ParsedDocument(units: Array(s.utf16)) }

/// What the source says, rebuilt from atoms and mark delimiters alone. If this
/// equals the source, every byte of a block is accounted for, which is what makes
/// zero-diff block edits possible.
func rebuild(_ atoms: [Atom], _ u: [UInt16]) -> [UInt16] {
    var out: [UInt16] = []
    var stack: [Mark] = []
    var i = 0
    while i < atoms.count {
        let atom = atoms[i]
        var common = 0
        while common < stack.count, common < atom.marks.count, stack[common] == atom.marks[common] { common += 1 }
        while stack.count > common { out += stack.removeLast().close }
        for mark in atom.marks[common...] {
            out += mark.open
            stack.append(mark)
        }
        var j = i + 1
        while j < atoms.count, atoms[j].range == atom.range, atom.range.count > 1 { j += 1 } // an entity's atoms
        out += u[atom.range]
        i = j
    }
    while let mark = stack.popLast() { out += mark.close }
    return out
}

private func slices(_ s: String, _ pick: (Inline) -> Bool) -> [String] {
    let doc = parse(s)
    var out: [String] = []
    func walk(_ inline: Inline) {
        if pick(inline) { out.append(String(decoding: doc.units[inline.range], as: UTF16.self)) }
        for child in inline.children { walk(child) }
    }
    for leaf in doc.leaves() { for inline in leaf.inlines { walk(inline) } }
    return out
}

private func isMark(_ wanted: Mark.Kind) -> (Inline) -> Bool {
    { inline in
        if case .mark(let m) = inline.kind { return m.kind == wanted }
        return false
    }
}

private func isEmphasis(_ inline: Inline) -> Bool { isMark(.emphasis)(inline) }

@Suite("Parser")
struct ParserTests {
    @Test("Every byte of every block is accounted for", arguments: Fixtures.all)
    func fixturesRebuild(name: String) throws {
        let units = TextCodec.decode(try Fixtures.data(name)).units
        let doc = ParsedDocument(units: units)
        for leaf in doc.leaves() where !leaf.isOpaque {
            if case .code = leaf.kind { continue }
            #expect(rebuild(leaf.atoms, units) == Array(units[leaf.content]), "\(name) at \(leaf.range)")
        }
    }

    /// Set MARKLIGHT_CORPUS to a file listing Markdown paths to run this on real
    /// documents. It's skipped otherwise, so the suite stays self-contained.
    @Test func corpusRebuilds() throws {
        guard let list = ProcessInfo.processInfo.environment["MARKLIGHT_CORPUS"] else { return }
        var leaves = 0, opaque = 0
        for path in try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n") {
            guard let data = FileManager.default.contents(atPath: String(path)) else { continue }
            let units = TextCodec.decode(data).units
            let doc = ParsedDocument(units: units)
            for leaf in doc.leaves() {
                leaves += 1
                if leaf.isOpaque { opaque += 1; continue }
                if case .code = leaf.kind { continue }
                #expect(rebuild(leaf.atoms, units) == Array(units[leaf.content]), "\(path) at \(leaf.range)")
            }
        }
        print("corpus: \(leaves) leaves, \(opaque) opaque")
    }

    // The inline position bugs from Spike 1.
    @Test func afterABackslashBreak() {
        #expect(slices("a\\\nb *c*\nd *e*\n", isEmphasis) == ["*c*", "*e*"])
    }

    @Test func afterALinkSplitAcrossLines() {
        #expect(slices("[a](\nhttp://x) *b*\nc *d*\n", isEmphasis) == ["*b*", "*d*"])
    }

    @Test func onALazyContinuationLine() {
        #expect(slices("- item\nlazy *em*\n", isEmphasis) == ["*em*"])
        #expect(slices("> quote\nlazy *em*\n", isEmphasis) == ["*em*"])
    }

    @Test func onAnIndentedContinuationLine() {
        #expect(slices("plain\n   *em* end\n", isEmphasis) == ["*em*"])
    }

    @Test func afterAnEscapedPipe() {
        #expect(slices("| a |\n|---|\n| x\\|y *z* |\n", isEmphasis) == ["*z*"])
    }

    @Test func setextHeadingStopsAtItsUnderline() {
        let doc = parse("Foo\n---\nbar\n")
        #expect(doc.root.children[0].range == 0..<7)
        #expect(doc.root.children[1].kind == .paragraph)
    }

    @Test func multibyteAndCRLF() {
        #expect(slices("# 标题 🚀 *強調*\r\n\r\n前文 **粗 🎉** `码`\r\n", isEmphasis) == ["*強調*"])
    }

    @Test func emptyTableCellDoesntTakeThePipe() {
        let doc = parse("| a | b |\n|---|---|\n| x |   |\n")
        let cell = doc.root.children[0].children[1].children[1]
        #expect(cell.atoms.isEmpty)
        #expect(doc.units[cell.content.lowerBound] != 0x7C)
    }

    @Test func frontMatterIsNotABreakAndHeading() {
        let doc = parse("---\ntitle: x\n---\n\n# Real\n")
        #expect(doc.root.children.map(\.kind) == [.frontMatter, .heading(1)])
        #expect(doc.root.children[0].range == 0..<17)
        #expect(String(decoding: doc.units[doc.root.children[1].range], as: UTF16.self) == "# Real")
    }

    @Test func aRuleAtTheStartIsNotFrontMatter() {
        let doc = parse("---\n\ntext\n")
        #expect(doc.root.children.map(\.kind) == [.rule, .paragraph])
    }

    @Test func unmappableTextIsOpaqueNotWrong() {
        let doc = parse("Before NUL\0after *em*\n")
        #expect(doc.leaves().allSatisfy { $0.isOpaque })
    }
}

@Suite("Highlighter")
struct HighlighterTests {
    private func styled(_ s: String) -> [(String, HighlightSpan.Style)] {
        let doc = parse(s)
        return Highlighter.spans(doc).map { (String(decoding: doc.units[$0.range], as: UTF16.self), $0.style) }
    }

    private func has(_ s: String, _ text: String, _ style: HighlightSpan.Style) -> Bool {
        styled(s).contains { $0.0 == text && $0.1 == style }
    }

    @Test func headings() {
        #expect(has("## Title ##\n", "## Title ##", .heading(2)))
        #expect(has("## Title ##\n", "## ", .syntax))
        #expect(has("## Title ##\n", " ##", .syntax))
        #expect(has("Title\n===\n", "\n===", .syntax))
    }

    @Test func inlineMarks() {
        let s = "a **b** *c* ~~d~~ `e`\n"
        #expect(has(s, "**b**", .strong))
        #expect(has(s, "**", .syntax))
        #expect(has(s, "*c*", .emphasis))
        #expect(has(s, "~~d~~", .strikethrough))
        #expect(has(s, "`e`", .code))
    }

    @Test func links() {
        let s = "[text](https://e.com \"t\") ![i](x.png) <https://a.b>\n"
        #expect(has(s, "text", .link))
        #expect(has(s, "(https://e.com \"t\")", .url))
        #expect(has(s, "![i](x.png)", .image))
        #expect(has(s, "https://a.b", .link))
    }

    @Test func referenceDefinitions() {
        let s = "[a][r]\n\n[r]: /u \"t\"\n"
        #expect(has(s, "[r]:", .syntax))
        #expect(has(s, " /u \"t\"", .url))
    }

    @Test func blocks() {
        #expect(has("- a\n1. b\n", "- ", .listMarker))
        #expect(has("- [x] a\n", "[x]", .listMarker))
        #expect(has("> a\n> b\n", ">", .quoteMarker))
        #expect(styled("> a\n> b\n").filter { $0.1 == .quoteMarker }.count == 2)
        #expect(styled("> > a\n> > b\n").filter { $0.1 == .quoteMarker }.count == 4)
        #expect(has("---\n\nx\n", "---", .rule))
        #expect(has("<div>\nx\n</div>\n", "<div>\nx\n</div>", .html))
        #expect(has("---\na: b\n---\n", "---\na: b\n---\n", .frontMatter))
    }

    @Test func codeBlocks() {
        let s = "```swift\nlet x\n```\n"
        #expect(has(s, "```swift\nlet x\n```", .codeBlock))
        #expect(has(s, "```swift", .syntax))
        #expect(has(s, "```", .syntax))
        #expect(has("    code\n", "code", .codeBlock))
    }

    @Test func tables() {
        let s = "| a | b |\n|---|---|\n| c | d |\n"
        #expect(has(s, "|---|---|", .syntax))
        #expect(styled(s).filter { $0.0 == "|" && $0.1 == .syntax }.count == 6)
    }

    @Test func escapes() {
        #expect(has("a \\* b &amp; c\n", "\\*", .escape))
        #expect(has("a \\* b &amp; c\n", "&amp;", .escape))
    }

    @Test func invalidBytes() {
        let buffer = Buffer(contentsOf: Data([0x61, 0xFF, 0x62, 0x0A]))
        let spans = Highlighter.spans(ParsedDocument(units: buffer.units))
        #expect(spans.contains { $0.style == .invalidByte && $0.range == 1..<3 })
    }

    @Test("Spans stay in bounds and never split a pair", arguments: Fixtures.all)
    func fixtures(name: String) throws {
        let units = TextCodec.decode(try Fixtures.data(name)).units
        for span in Highlighter.spans(ParsedDocument(units: units)) {
            #expect(span.range.lowerBound >= 0 && span.range.upperBound <= units.count, "\(name) \(span)")
            if span.range.upperBound < units.count {
                #expect(!(0xDC00..<0xE000).contains(units[span.range.upperBound]), "\(name) \(span)")
            }
        }
    }
}
