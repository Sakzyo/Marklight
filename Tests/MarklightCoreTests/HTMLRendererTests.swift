import Foundation
import Testing
@testable import MarklightCore

private func parse(_ s: String) -> ParsedDocument { ParsedDocument(units: Array(s.utf16)) }

private func render(_ s: String) -> RenderedDocument { HTMLRenderer.render(parse(s)) }

private func html(_ s: String) -> String { render(s).blocks.map(\.html).joined() }

/// One opening tag in Marklight's own output. Text and attribute values escape `<`
/// and `>`, so a tag can be found without an HTML parser.
private struct Tag {
    let name: String
    let attributes: String

    var isRaw: Bool { attributes.contains(" data-raw") }
    var isRun: Bool { attributes.contains(" data-run") || attributes.hasPrefix("data-run") }
    var isAtomic: Bool { attributes.contains("data-atomic") }

    var src: Range<Int>? {
        guard let match = attributes.range(of: #"data-src="\d+:\d+""#, options: .regularExpression) else { return nil }
        let parts = attributes[match].dropFirst(10).dropLast().split(separator: ":").map { Int($0)! }
        return parts[0]..<parts[1]
    }
}

private func tags(_ html: String) -> [Tag] {
    let expression = try! NSRegularExpression(pattern: "<([a-z][a-z0-9]*)( [^>]*)?>")
    let text = html as NSString
    return expression.matches(in: html, range: NSRange(location: 0, length: text.length)).map {
        let attributes = $0.range(at: 2).location == NSNotFound ? "" : text.substring(with: $0.range(at: 2))
        return Tag(name: text.substring(with: $0.range(at: 1)), attributes: attributes)
    }
}

private func fixture(_ name: String) throws -> ParsedDocument {
    ParsedDocument(units: TextCodec.decode(try Fixtures.data(name)).units)
}

@Suite("HTML renderer")
struct HTMLRendererTests {
    // MARK: - Output contract

    @Test("Every element has valid, in-bounds data-src", arguments: Fixtures.all)
    func sourceRanges(name: String) throws {
        let doc = try fixture(name)
        let rendered = HTMLRenderer.render(doc)
        #expect(rendered.length == doc.units.count)
        var last = -1
        for block in rendered.blocks {
            #expect(block.base > last || (block.base == 0 && last == -1), "\(name): bases must rise, so the page can search them")
            last = block.base
            #expect(block.base >= 0 && block.base <= doc.units.count)
            for tag in tags(block.html) {
                if tag.name == "td" || tag.name == "th", tag.src == nil { continue } // GFM's padding cells
                let range = try #require(tag.src, "\(name): <\(tag.name)\(tag.attributes)> has no data-src in \(block.html)")
                #expect(block.base + range.upperBound <= doc.units.count, "\(name): <\(tag.name)\(tag.attributes)> is out of bounds")
            }
        }
    }

    @Test("A run's text matches its source, unit for unit", arguments: Fixtures.all)
    func runsMatchSource(name: String) throws {
        let doc = try fixture(name)
        for block in HTMLRenderer.render(doc).blocks {
            let expression = try NSRegularExpression(pattern: #"<span data-run data-src="(\d+):(\d+)">([^<]*)</span>"#)
            let text = block.html as NSString
            for match in expression.matches(in: block.html, range: NSRange(location: 0, length: text.length)) {
                let start = Int(text.substring(with: match.range(at: 1)))!, end = Int(text.substring(with: match.range(at: 2)))!
                let shown = text.substring(with: match.range(at: 3)).replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
                let source = Array(doc.units[(block.base + start)..<(block.base + end)])
                #expect(shown.utf16.count == end - start, "\(name): run \(start):\(end) shows \(shown.utf16.count) units")
                // Inline code shows a line break as a space, and the parser's U+FFFD stands in for NUL.
                let expected = source.map { $0 == 0 ? 0xFFFD : $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 }
                #expect(Array(shown.utf16) == expected, "\(name): run \(start):\(end)")
            }
        }
    }

    @Test("Offsets are relative to the top-level block")
    func relativeOffsets() {
        let blocks = render("first\n\n- *a*\n").blocks
        #expect(blocks.map(\.base) == [0, 7])
        #expect(blocks[1].html.hasPrefix(#"<ul data-src="0:5"><li data-src="0:5"><p data-src="2:5"><em data-src="2:5"><span data-run data-src="3:4">a</span></em></p></li></ul>"#))
    }

    @Test("Offsets count UTF-16 units, past emoji and CJK")
    func astralOffsets() {
        let blocks = render("😀 **漢字**\n").blocks
        #expect(blocks[0].html == #"<p data-src="0:9"><span data-run data-src="0:3">😀 </span><strong data-src="3:9"><span data-run data-src="5:7">漢字</span></strong></p>"#)
    }

    @Test("A block's HTML doesn't change when text above it does", arguments: Fixtures.all)
    func stableUnderEditsAbove(name: String) throws {
        let doc = try fixture(name)
        let before = HTMLRenderer.render(doc)
        let inserted = Array("# A new heading\n\nAnd a [new](paragraph) above it.\n\n".utf16)
        guard !doc.root.children.contains(where: { $0.kind == .frontMatter }) else { return } // has to stay on line 1
        let after = HTMLRenderer.render(ParsedDocument(units: inserted + doc.units))
        let shifted = after.blocks.suffix(before.blocks.count)
        #expect(shifted.map(\.html) == before.blocks.map(\.html), "\(name)")
        #expect(shifted.map(\.base) == before.blocks.map { $0.base + inserted.count }, "\(name)")
    }

    // MARK: - Escaping

    @Test("A link can't break out of its attribute")
    func linkBreakout() {
        let out = html(#"[x](<x" onmouseover="alert(1)" data-x=">)"# + "\n")
        #expect(out.contains(#"href="x&quot; onmouseover=&quot;alert(1)&quot; data-x=&quot;""#))
        #expect(tags(out).allSatisfy { !$0.attributes.contains("onmouseover=\"") })
    }

    @Test("Attributes escape all five characters")
    func attributes() {
        let out = html(#"[x](<a&b'c"d>)"# + "\n")
        #expect(out.contains(#"href="a&amp;b&#39;c&quot;d""#))
    }

    @Test("Images keep escaped alt text")
    func imageAlt() {
        let out = html(##"![a "b" <c> & 'd'](x.png)"## + "\n")
        #expect(out.contains(#"alt="a &quot;b&quot; &lt;c&gt; &amp; &#39;d&#39;""#))
        #expect(out.contains(#"src="x.png""#))
        #expect(out.contains("<img data-run data-atomic"))
    }

    @Test("An image's source can't break out of its attribute")
    func imageBreakout() {
        let out = html(#"![x](<a" onerror="alert(1)>)"# + "\n")
        #expect(out.contains(#"src="a&quot; onerror=&quot;alert(1)""#))
    }

    @Test("Text and code are escaped")
    func textEscaping() {
        #expect(html("a &amp; \\<b\\>\n").contains("&amp;"))
        #expect(html("`<script>`\n").contains("&lt;script&gt;"))
        #expect(html("```\n<script>alert(1)</script>\n```\n").contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    @Test("A code block's language can't break out of its attribute")
    func languageBreakout() {
        let out = html("```a\"><img\nx\n```\n")
        #expect(!out.contains("<img"))
        #expect(out.contains("language-a&quot;&gt;&lt;img"))
    }

    @Test("Raw HTML stays escaped text until the page sanitizes it")
    func rawHTML() {
        let out = html("<div onclick=\"x\">a</div></div><p data-src=\"0:99\">forged</p>\n")
        #expect(out.hasPrefix(#"<div data-src="#))
        #expect(out.contains(" data-raw>&lt;div onclick=\"x\"&gt;"))
        let found = tags(out)
        #expect(found.count == 1, "only Marklight's own element should be real markup: \(found)")
    }

    @Test("Raw HTML in a quote loses the quote's prefix")
    func rawHTMLPrefix() {
        let out = html("> <div>\n> a\n> </div>\n")
        #expect(out.contains("&lt;div&gt;\na\n&lt;/div&gt;"))
    }

    @Test("Inline HTML is a literal chip")
    func inlineHTML() {
        let out = html("a <kbd>b</kbd> c\n")
        #expect(out.contains(#"class="inline-html">&lt;kbd&gt;</span>"#))
        #expect(tags(out).allSatisfy { $0.name != "kbd" })
    }

    // MARK: - Blocks

    @Test("Straight quotes stay straight")
    func straightQuotes() {
        let out = html("\"quoted\" -- it's...\n")
        #expect(out.contains("\"quoted\" -- it's..."))
    }

    @Test("Headings, rules, quotes, and lists")
    func structure() {
        #expect(html("## Title ##\n").hasPrefix("<h2 "))
        #expect(html("Title\n===\n").hasPrefix("<h1 "))
        #expect(html("---\n\ntext\n").contains("<hr "))
        #expect(html("> a\n").hasPrefix("<blockquote "))
        #expect(html("3. a\n4. b\n").hasPrefix(#"<ol data-src="0:9" start="3">"#))
        #expect(html("1. a\n").hasPrefix(#"<ol data-src="0:4">"#))
    }

    @Test("Inline marks")
    func marks() {
        let out = html("**a** *b* ~~c~~ `d` [e](f)\n")
        for tag in ["strong", "em", "del", "code", "a"] {
            #expect(tags(out).contains { $0.name == tag }, "\(tag)")
        }
    }

    @Test("Task items show a disabled checkbox")
    func taskItems() {
        let out = html("- [x] done\n- [ ] open\n- plain\n")
        let boxes = tags(out).filter { $0.name == "input" }
        #expect(boxes.count == 2)
        #expect(boxes.allSatisfy { $0.attributes.contains(" disabled") && $0.attributes.contains(#"type="checkbox""#) })
        #expect(boxes[0].attributes.contains(" checked"))
        #expect(!boxes[1].attributes.contains(" checked"))
    }

    @Test("An empty list item keeps a caret position")
    func emptyItem() {
        #expect(html("- \n- b\n").contains("data-caret"))
    }

    @Test("Code blocks carry their language, and each line is its own run")
    func codeBlocks() {
        let out = html("```swift extra\nlet a\nlet b\n```\n")
        #expect(out.contains(#"class="language-swift""#))
        #expect(tags(out).filter(\.isRun).count == 3)
    }

    @Test("An empty code block has a caret position")
    func emptyCode() {
        #expect(html("```\n```\n").contains("data-caret"))
    }

    @Test("CRLF code keeps its offsets")
    func crlfCode() {
        let doc = parse("```\r\na\r\nb\r\n```\r\n")
        let block = HTMLRenderer.render(doc).blocks[0]
        let runs = tags(block.html).filter(\.isRun).compactMap(\.src)
        #expect(runs == [5..<6, 6..<8, 8..<9])
    }

    @Test("Mermaid and math show as code for now")
    func mermaid() {
        #expect(html("```mermaid\ngraph TD\n```\n").contains(#"<pre data-src="0:23" class="language-mermaid">"#))
        #expect(html("```math\nx\n```\n").contains("language-math"))
    }

    @Test("Front matter is a plain block")
    func frontMatter() {
        let blocks = render("---\ntitle: x <y>\n---\n\n# Body\n").blocks
        #expect(blocks.count == 2)
        #expect(blocks[0].html.hasPrefix(#"<pre data-src="0:21" class="front-matter">"#))
        #expect(blocks[0].html.contains("title: x &lt;y&gt;"))
        #expect(blocks[1].html.hasPrefix("<h1 "))
    }

    @Test("Tables have thead, tbody, alignment, and padded rows")
    func tables() {
        let out = html("| a | b | c |\n|:--|:-:|--:|\n| 1 |\n| 1 | 2 | 3 |\n")
        let found = tags(out)
        #expect(found.filter { $0.name == "thead" }.count == 1)
        #expect(found.filter { $0.name == "tbody" }.count == 1)
        #expect(found.filter { $0.name == "th" }.map(\.attributes).map { $0.contains(#"align="left""#) } == [true, false, false])
        #expect(found.filter { $0.name == "th" }[1].attributes.contains(#"align="center""#))
        #expect(found.filter { $0.name == "th" }[2].attributes.contains(#"align="right""#))
        #expect(found.filter { $0.name == "td" }.count == 6, "the short row is padded: \(out)")
        #expect(found.filter { $0.name == "td" && $0.src == nil }.count <= 2)
    }

    @Test("A table with no body has no tbody")
    func headOnlyTable() {
        #expect(!html("| a |\n|---|\n").contains("<tbody"))
    }

    @Test("A document with no blocks renders nothing", arguments: ["", "\n\n", "   \n", "[a]: b\n"])
    func emptyDocuments(text: String) {
        #expect(render(text).blocks.isEmpty)
    }

    @Test("A NUL can't shift a run's offsets")
    func nul() throws {
        let doc = try fixture("nul.md")
        let out = HTMLRenderer.render(doc).blocks.map(\.html).joined()
        #expect(!out.unicodeScalars.contains("\0"))
    }

    // MARK: - Remote images

    @Test("Finds https images", arguments: [
        "![a](https://example.com/a.png)\n",
        "![a](HTTPS://example.com/a.png)\n",
        "[![badge](https://img.shields.io/x.svg)](https://example.com)\n",
        "- ![a](https://example.com/a.png)\n",
        "<img src=\"https://example.com/a.png\">\n",
        "<p><img width=\"1\" src='https://example.com/a.png'></p>\n",
        "<img src=https://example.com/a.png>\n",
        "<picture>\n<source srcset=\"https://example.com/a.png\">\n</picture>\n",
        "<p style=\"background:url(https://example.com/a.png)\">x</p>\n",
    ])
    func remoteImages(text: String) {
        #expect(render(text).hasRemoteImages, "\(text)")
    }

    @Test("Ignores everything else", arguments: [
        "![a](a.png)\n",
        "![a](http://example.com/a.png)\n",
        "[a](https://example.com/a.png)\n",
        "`![a](https://example.com/a.png)`\n",
        "```\n![a](https://example.com/a.png)\n```\n",
        "<a href=\"https://example.com\">x</a>\n",
        "a <img src=\"https://example.com/a.png\"> b\n", // inline HTML is a chip
    ])
    func noRemoteImages(text: String) {
        #expect(!render(text).hasRemoteImages, "\(text)")
    }

    @Test("A local render agrees with a fresh render, including images and shifted offsets")
    func incrementalRender() throws {
        let text = "![image](https://example.com/a.png)\n\nfirst\n\nsecond **bold**\n\nthird\n\nlast"
        let doc = IncrementalDocument(units: Array(text.utf16))
        let old = HTMLRenderer.render(doc, pending: nil)
        let at = (text as NSString).range(of: "bold").location + 2
        let patch = Patch(range: at..<at, replacement: Array("字🦉".utf16), origin: .rendered)
        let next = doc.applying(patch)
        #expect(!next.usedFullParse)
        let local = HTMLRenderer.render(next, pending: nil, reusing: old, patch: patch)
        let fresh = HTMLRenderer.render(ParsedDocument(units: next.units))
        #expect(local == fresh)
        #expect(local.hasRemoteImages)
        #expect(old.patch(to: local).list.count == 1)
    }

    @Test("A pending paragraph has a real caret without adding source bytes")
    func pendingParagraph() {
        let doc = IncrementalDocument(units: Array("before\n\n\n\nafter".utf16))
        let out = HTMLRenderer.render(doc, pending: 8)
        #expect(out.blocks.count == 3)
        #expect(out.blocks[1].base == 8)
        #expect(out.blocks[1].html.contains(#"data-caret="0"><br data-src="0:0">"#))
        #expect(out.length == doc.units.count)
        for text in ["- ", "> ", "# "] {
            #expect(html(text).contains(#"><br data-src="#), "empty leaf in \(text)")
        }
    }

    @Test("Changing the order of combining marks reaches the DOM")
    func exactUnits() {
        let a = render("a\u{0315}\u{0300}"), b = render("a\u{0300}\u{0315}")
        #expect(a.patch(to: b).list.count == 1)
    }

    // MARK: - Block patches

    private func apply(_ patch: BlockPatch, to old: RenderedDocument) -> [RenderedBlock] {
        let tail = old.blocks[(patch.from + patch.remove)...].map { RenderedBlock(html: $0.html, base: $0.base + patch.delta) }
        return Array(old.blocks[..<patch.from]) + patch.list + tail
    }

    @Test("A patch covers only what changed")
    func patchIsMinimal() {
        let old = render("one\n\ntwo\n\nthree\n"), new = render("one\n\ntwo!\n\nthree\n")
        let patch = old.patch(to: new)
        #expect(patch.from == 1)
        #expect(patch.remove == 1)
        #expect(patch.list.count == 1)
        #expect(patch.delta == 1)
        #expect(apply(patch, to: old) == new.blocks)
    }

    @Test("Text outside any block moves later blocks without resending them")
    func patchBlankLines() {
        let old = render("one\n\ntwo\n"), new = render("one\n\n\n\ntwo\n")
        let patch = old.patch(to: new)
        #expect(patch.remove == 0)
        #expect(patch.list.isEmpty)
        #expect(patch.delta == 2)
        #expect(apply(patch, to: old) == new.blocks)
    }

    @Test("Blocks identical to their neighbours aren't confused")
    func patchRepeats() {
        let old = render("a\n\na\n\na\n"), new = render("a\n\na\n\na\n\na\n")
        #expect(apply(old.patch(to: new), to: old) == new.blocks)
        #expect(apply(new.patch(to: old), to: new) == old.blocks)
    }

    @Test("Changes in two places, and uneven trailing text, still patch exactly")
    func patchTwoPlaces() {
        let old = render("a\n\nb\n\nc\n"), new = render("aa\n\nb\n\ncc\n\n\n")
        #expect(apply(old.patch(to: new), to: old) == new.blocks)
        let growth = render("x\n\ny\n"), later = render("xx\n\ny\n\n")
        #expect(apply(growth.patch(to: later), to: growth) == later.blocks)
    }

    @Test("Any pair of fixtures patches into the other")
    func patchFixtures() throws {
        let rendered = try Fixtures.all.map { HTMLRenderer.render(try fixture($0)) }
        for (a, b) in zip(rendered, rendered.dropFirst()) {
            #expect(apply(a.patch(to: b), to: a) == b.blocks)
        }
    }
}
