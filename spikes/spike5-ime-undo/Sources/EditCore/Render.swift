import Foundation

public struct RenderedBlock: Equatable {
    public let html: String
    public let base: Int
}

/// Renders each top-level block with `data-src` relative to the block's start, so
/// a block's HTML doesn't change when text above it does. Add the block's `base`
/// for a source offset. Text sits in runs marked `data-run`: DOM offset plus run
/// start is the offset, unless the run is `data-atomic`.
public enum Renderer {
    public static func blocks(_ doc: DocModel, pending: Int? = nil) -> [RenderedBlock] {
        var out: [RenderedBlock] = []
        var left = pending
        func placeholder(_ at: Int) {
            var r = Render(units: doc.units, pending: nil, base: at)
            r.placeholder(at)
            out.append(RenderedBlock(html: r.out, base: at))
        }
        for child in doc.root.children {
            if let p = left, p <= child.range.lowerBound {
                placeholder(p)
                left = nil
            }
            var r = Render(units: doc.units, pending: left, base: child.range.lowerBound)
            r.block(child)
            left = r.pending
            out.append(RenderedBlock(html: r.out, base: child.range.lowerBound))
        }
        if let p = left { placeholder(p) }
        return out
    }

    public static func html(_ doc: DocModel, pending: Int? = nil) -> String {
        blocks(doc, pending: pending).map { $0.html }.joined()
    }
}

private func attr(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func text(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private struct Render {
    let units: [UInt16]
    var pending: Int?
    var base = 0
    var out = ""

    func src(_ r: Range<Int>) -> String { "data-src=\"\(r.lowerBound - base):\(r.upperBound - base)\"" }

    func caretAttr(_ at: Int) -> String { "data-caret=\"\(at - base)\"" }

    mutating func placeholder(_ at: Int) {
        out += "<p \(src(at..<at)) \(caretAttr(at))><br></p>"
        pending = nil
    }

    mutating func children(of b: Block) {
        for child in b.children {
            if let p = pending, p <= child.range.lowerBound { placeholder(p) }
            block(child)
        }
    }

    mutating func block(_ b: Block) {
        switch b.kind {
        case .paragraph: leaf(b, "p")
        case .heading(let n): leaf(b, "h\(n)")
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
            out += "<li \(src(b.range))>"
            if let checked {
                out += "<input type=\"checkbox\" contenteditable=\"false\" \(src(b.range))\(checked ? " checked" : "")>"
            }
            if b.children.isEmpty {
                var e = b.range.lowerBound
                while e < units.count, !units[e].isLineBreak { e += 1 }
                out += "<p \(src(e..<e)) \(caretAttr(e))><br></p>"
            }
            children(of: b)
            out += "</li>"
        case .code(let info):
            let cls = info.isEmpty ? "" : " data-lang=\"\(attr(info))\""
            out += "<pre \(src(b.range))\(cls)><code \(src(b.content)) \(caretAttr(b.content.lowerBound))>"
            runs(b, 0..<b.atoms.count)
            out += "</code></pre>"
        case .html:
            let raw = String(decoding: units[b.range], as: UTF16.self)
            out += "<div \(src(b.range)) contenteditable=\"false\" data-raw>\(raw)</div>"
        case .rule:
            out += "<hr \(src(b.range)) contenteditable=\"false\">"
        case .table:
            out += "<table \(src(b.range))>"
            children(of: b)
            out += "</table>"
        case .row(let header):
            out += header ? "<thead><tr \(src(b.range))>" : "<tr \(src(b.range))>"
            children(of: b)
            out += header ? "</tr></thead>" : "</tr>"
        case .cell:
            let header: Bool
            if case .row(true)? = b.parent?.kind { header = true } else { header = false }
            leaf(b, header ? "th" : "td")
        case .document:
            children(of: b)
        }
    }

    mutating func leaf(_ b: Block, _ tag: String) {
        if b.opaque {
            let raw = String(decoding: units[b.range], as: UTF16.self)
            out += "<\(tag) \(src(b.range)) contenteditable=\"false\" data-opaque>\(text(raw))</\(tag)>"
            return
        }
        out += "<\(tag) \(src(b.range)) \(caretAttr(b.content.lowerBound))>"
        if b.atoms.isEmpty {
            out += "<br>"
        } else {
            var cursor = 0
            inlines(b, b.inlines, &cursor)
            if cursor < b.atoms.count { runs(b, cursor..<b.atoms.count) } // trailing whitespace
        }
        out += "</\(tag)>"
    }

    mutating func inlines(_ b: Block, _ nodes: [Inline], _ cursor: inout Int) {
        for node in nodes {
            switch node.kind {
            case .run:
                runs(b, node.atoms)
            case .mark(let m):
                let tag: String
                var extra = ""
                switch m.kind {
                case .strong: tag = "strong"
                case .em: tag = "em"
                case .strike: tag = "del"
                case .code: tag = "code"
                case .link(let dest):
                    tag = "a"
                    extra = " href=\"\(attr(dest))\""
                }
                out += "<\(tag) \(src(node.range))\(extra)>"
                var inner = node.atoms.lowerBound
                inlines(b, node.children, &inner)
                out += "</\(tag)>"
            case .image(let source, let alt):
                out += "<img data-run data-atomic \(src(node.range)) contenteditable=\"false\" src=\"\(attr(source))\" alt=\"\(attr(alt))\">"
            case .html(let raw):
                out += "<span data-run data-atomic \(src(node.range)) contenteditable=\"false\" data-rawhtml>\(text(raw))</span>"
            }
            cursor = max(cursor, node.atoms.upperBound)
        }
    }

    mutating func runs(_ b: Block, _ range: Range<Int>) {
        var i = range.lowerBound
        while i < range.upperBound {
            let atom = b.atoms[i]
            let r = atom.range!
            switch atom.kind {
            case .hardBreak:
                out += "<br data-run data-atomic \(src(r))>"
                i += 1
            case .softBreak:
                let isCode: Bool
                if case .code = b.kind { isCode = true } else { isCode = false }
                out += "<span data-run data-atomic \(src(r))>\(isCode ? "\n" : " ")</span>"
                i += 1
            case .object:
                i += 1
            case .text, .ignored:
                var j = i + 1
                if r.count == 1 {
                    while j < range.upperBound, let n = b.atoms[j].range, n.count == 1, n.lowerBound == b.atoms[j - 1].range!.upperBound,
                          b.atoms[j].kind == .text || b.atoms[j].kind == .ignored { j += 1 }
                } else {
                    while j < range.upperBound, b.atoms[j].range == r { j += 1 }
                }
                let s = String(decoding: b.atoms[i..<j].map { $0.unit }, as: UTF16.self)
                let span = r.lowerBound..<b.atoms[j - 1].range!.upperBound
                out += "<span data-run\(r.count == 1 ? "" : " data-atomic") \(src(span))>\(text(s))</span>"
                i = j
            }
        }
    }
}
