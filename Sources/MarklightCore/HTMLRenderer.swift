import Foundation

/// One top-level block. Every `data-src` in `html` is relative to `base`, so a
/// block's HTML doesn't change when text above it does (`docs/contracts.md`).
public struct RenderedBlock: Equatable, Sendable {
    public let html: String
    public let base: Int

    public init(html: String, base: Int) {
        self.html = html
        self.base = base
    }
}

/// What turns one rendered document into another: replace `remove` blocks at
/// `from` with `list`, then add `delta` to the offset of every block after them.
public struct BlockPatch: Equatable, Sendable {
    public let from: Int
    public let remove: Int
    public let list: [RenderedBlock]
    public let delta: Int
}

public struct RenderedDocument: Equatable, Sendable {
    public let blocks: [RenderedBlock]
    /// The source's length in UTF-16 units.
    public let length: Int
    /// Whether "Load remote images" would change anything, so `https` images only.
    /// This decides whether to offer the bar. The CSP does the blocking, so a miss
    /// here costs a missing bar, not a request.
    public let hasRemoteImages: Bool

    public init(blocks: [RenderedBlock], length: Int, hasRemoteImages: Bool) {
        self.blocks = blocks
        self.length = length
        self.hasRemoteImages = hasRemoteImages
    }

    /// The patch from this document to `new`. Blocks outside it are unchanged, and
    /// the page never has to touch their DOM nodes.
    public func patch(to new: RenderedDocument) -> BlockPatch {
        let old = blocks
        let next = new.blocks
        var head = 0
        while head < old.count, head < next.count, old[head] == next[head] { head += 1 }
        let delta = new.length - length
        var tail = 0
        while tail < old.count - head, tail < next.count - head {
            let a = old[old.count - 1 - tail], b = next[next.count - 1 - tail]
            guard a.base + delta == b.base, a.html == b.html else { break }
            tail += 1
        }
        return BlockPatch(from: head, remove: old.count - head - tail, list: Array(next[head..<(next.count - tail)]), delta: delta)
    }
}

/// Turns a parsed document into HTML, one top-level block at a time.
///
/// The output is untrusted: it carries the document's URLs, and the page sanitizes
/// it before it reaches the DOM. Swift still escapes every attribute itself. Raw
/// HTML travels as escaped text inside a `data-raw` element, and the page sanitizes
/// and expands it there, so a stray `</div>` in it can't climb out of the element
/// and forge offsets. swift-markdown's `HTMLFormatter` can't be used here: it
/// doesn't escape attributes and it drops image `alt` text (Spike 6).
public enum HTMLRenderer {
    public static func render(_ doc: ParsedDocument) -> RenderedDocument {
        var blocks: [RenderedBlock] = []
        blocks.reserveCapacity(doc.root.children.count)
        var hasRemoteImages = false
        for child in doc.root.children {
            var writer = BlockWriter(units: doc.units, base: child.range.lowerBound)
            writer.block(child)
            blocks.append(RenderedBlock(html: writer.out, base: child.range.lowerBound))
            hasRemoteImages = hasRemoteImages || writer.foundRemoteImage
        }
        return RenderedDocument(blocks: blocks, length: doc.units.count, hasRemoteImages: hasRemoteImages)
    }
}

/// Escapes text for HTML, and for an attribute value when `attribute` is set. NUL
/// becomes U+FFFD, as the HTML parser would drop it and shift a run's DOM offsets.
private func escaped(_ s: String, attribute: Bool = false) -> String {
    let needsWork = s.utf8.contains { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0 || (attribute && ($0 == 0x22 || $0 == 0x27)) }
    guard needsWork else { return s }
    var out = ""
    out.reserveCapacity(s.utf8.count + 16)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"" where attribute: out += "&quot;"
        case "'" where attribute: out += "&#39;"
        case "\0": out += "\u{FFFD}"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

private func isRemoteImage(_ source: String) -> Bool {
    source.prefix(8).lowercased() == "https://"
}

/// An `https` image in raw HTML: `src`, `srcset`, or a CSS `url()`.
private func rawHTMLHasRemoteImage(_ html: String) -> Bool {
    let lowered = html.lowercased()
    guard lowered.contains("https:") else { return false }
    return lowered.range(of: #"(src|srcset)\s*=\s*["']?\s*https:|url\(\s*["']?\s*https:"#, options: .regularExpression) != nil
}

private struct BlockWriter {
    let units: [UInt16]
    let base: Int
    var out = ""
    var foundRemoteImage = false

    init(units: [UInt16], base: Int) {
        self.units = units
        self.base = base
    }

    private func src(_ range: Range<Int>) -> String {
        "data-src=\"\(range.lowerBound - base):\(range.upperBound - base)\""
    }

    private func caret(_ offset: Int) -> String {
        "data-caret=\"\(offset - base)\""
    }

    private func decoded(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    mutating func block(_ b: Block) {
        switch b.kind {
        case .document:
            children(of: b)
        case .frontMatter:
            out += "<pre \(src(b.range)) class=\"front-matter\"><code \(src(b.range))>"
            literal(b.range)
            out += "</code></pre>"
        case .paragraph:
            leaf(b, tag: "p")
        case .heading(let level):
            leaf(b, tag: "h\(level)")
        case .quote:
            out += "<blockquote \(src(b.range))>"
            children(of: b)
            out += "</blockquote>"
        case .list(let ordered, let start):
            if ordered {
                out += "<ol \(src(b.range))" + (start == 1 ? "" : " start=\"\(start)\"") + ">"
            } else {
                out += "<ul \(src(b.range))>"
            }
            children(of: b)
            out += ordered ? "</ol>" : "</ul>"
        case .item(let checked):
            item(b, checked: checked)
        case .code(let info):
            code(b, info: info)
        case .html:
            if rawHTMLHasRemoteImage(b.rawHTML) { foundRemoteImage = true }
            out += "<div \(src(b.range)) data-raw>\(escaped(b.rawHTML))</div>"
        case .rule:
            out += "<hr \(src(b.range))>"
        case .table:
            table(b)
        case .row, .cell:
            break // written by `table`, which knows the columns
        }
    }

    private mutating func children(of b: Block) {
        for child in b.children { block(child) }
    }

    private mutating func item(_ b: Block, checked: Bool?) {
        out += "<li \(src(b.range))>"
        if let checked {
            out += "<input type=\"checkbox\" disabled \(src(b.range))\(checked ? " checked" : "")>"
        }
        if b.children.isEmpty {
            let end = units.lineEnd(from: b.range.lowerBound)
            out += "<p \(src(end..<end)) \(caret(end))></p>"
        }
        children(of: b)
        out += "</li>"
    }

    private mutating func code(_ b: Block, info: String) {
        let language = info.split(whereSeparator: \.isWhitespace).first.map { " class=\"language-\(escaped(String($0), attribute: true))\"" } ?? ""
        out += "<pre \(src(b.range))\(language)>"
        if b.isOpaque {
            out += "<code \(src(b.range))>"
            literal(b.range)
        } else if b.atoms.isEmpty {
            out += "<code \(src(b.content)) \(caret(b.content.lowerBound))>"
        } else {
            out += "<code \(src(b.content))>"
            runs(b, 0..<b.atoms.count)
        }
        out += "</code></pre>"
    }

    private mutating func table(_ b: Block) {
        guard let head = b.children.first else { return }
        let columns = head.children.count
        let body = b.children.dropFirst()
        out += "<table \(src(b.range))><thead \(src(head.range))>"
        row(head, in: b, columns: columns)
        out += "</thead>"
        if let first = body.first, let last = body.last {
            out += "<tbody \(src(first.range.lowerBound..<last.range.upperBound))>"
            for line in body { row(line, in: b, columns: columns) }
            out += "</tbody>"
        }
        out += "</table>"
    }

    private mutating func row(_ b: Block, in table: Block, columns: Int) {
        var isHeader = false
        if case .row(header: true) = b.kind { isHeader = true }
        let tag = isHeader ? "th" : "td"
        out += "<tr \(src(b.range))>"
        for column in 0..<max(columns, b.children.count) {
            var align = ""
            if column < table.columnAlignments.count, let alignment = table.columnAlignments[column] {
                align = " align=\"\(alignment)\""
            }
            if column < b.children.count {
                leaf(b.children[column], tag: tag, attributes: align)
            } else {
                out += "<\(tag)\(align)></\(tag)>" // GFM pads a short row, with no source of its own
            }
        }
        out += "</tr>"
    }

    private mutating func leaf(_ b: Block, tag: String, attributes: String = "") {
        if b.isOpaque {
            out += "<\(tag) \(src(b.range))\(attributes) class=\"opaque\">\(escaped(decoded(b.range)))</\(tag)>"
            return
        }
        guard !b.atoms.isEmpty else {
            out += "<\(tag) \(src(b.range))\(attributes) \(caret(b.content.lowerBound))></\(tag)>"
            return
        }
        out += "<\(tag) \(src(b.range))\(attributes)>"
        var cursor = 0
        inlines(b, b.inlines, &cursor)
        if cursor < b.atoms.count { runs(b, cursor..<b.atoms.count) } // trailing whitespace
        out += "</\(tag)>"
    }

    private mutating func inlines(_ b: Block, _ nodes: [Inline], _ cursor: inout Int) {
        for node in nodes {
            switch node.kind {
            case .run:
                runs(b, node.atoms)
            case .mark(let mark):
                let tag: String
                var extra = ""
                switch mark.kind {
                case .strong: tag = "strong"
                case .emphasis: tag = "em"
                case .strikethrough: tag = "del"
                case .code: tag = "code"
                case .link(let destination):
                    tag = "a"
                    extra = " href=\"\(escaped(destination, attribute: true))\""
                }
                out += "<\(tag) \(src(node.range))\(extra)>"
                var inner = node.atoms.lowerBound
                inlines(b, node.children, &inner)
                out += "</\(tag)>"
            case .image(let source, let alt):
                if isRemoteImage(source) { foundRemoteImage = true }
                out += "<img data-run data-atomic \(src(node.range)) src=\"\(escaped(source, attribute: true))\" alt=\"\(escaped(alt, attribute: true))\">"
            case .html(let raw):
                out += "<span data-run data-atomic \(src(node.range)) class=\"inline-html\">\(escaped(raw))</span>"
            }
            cursor = max(cursor, node.atoms.upperBound)
        }
    }

    private mutating func runs(_ b: Block, _ range: Range<Int>) {
        var isCode = false
        if case .code = b.kind { isCode = true }
        var i = range.lowerBound
        while i < range.upperBound {
            let atom = b.atoms[i]
            switch atom.kind {
            case .hardBreak:
                out += "<br data-run data-atomic \(src(atom.range))>"
                i += 1
            case .softBreak:
                out += "<span data-run data-atomic \(src(atom.range))>\(isCode ? "\n" : " ")</span>"
                i += 1
            case .object:
                i += 1 // written by `inlines`
            case .text, .ignored:
                var j = i + 1
                if atom.range.count == 1 {
                    // 1:1 with the source, so DOM offsets line up with it.
                    while j < range.upperBound, b.atoms[j].range.count == 1, b.atoms[j].range.lowerBound == b.atoms[j - 1].range.upperBound,
                          b.atoms[j].kind == .text || b.atoms[j].kind == .ignored { j += 1 }
                } else {
                    while j < range.upperBound, b.atoms[j].range == atom.range { j += 1 } // an entity decoding to several units
                }
                let text = String(decoding: b.atoms[i..<j].map(\.unit), as: UTF16.self)
                let span = atom.range.lowerBound..<b.atoms[j - 1].range.upperBound
                out += "<span data-run\(atom.range.count == 1 ? "" : " data-atomic") \(src(span))>\(escaped(text))</span>"
                i = j
            }
        }
    }

    /// Source shown as written, with each line break a run of its own: the HTML
    /// parser turns CRLF into one unit, which would shift DOM offsets inside a run.
    private mutating func literal(_ range: Range<Int>) {
        var i = range.lowerBound
        while i < range.upperBound {
            var e = i
            while e < range.upperBound, !units[e].isLineBreak { e += 1 }
            if e > i { out += "<span data-run \(src(i..<e))>\(escaped(decoded(i..<e)))</span>" }
            guard e < range.upperBound else { break }
            let next = min(units.afterLineBreak(e), range.upperBound)
            out += "<span data-run data-atomic \(src(e..<next))>\n</span>"
            i = next
        }
    }
}
