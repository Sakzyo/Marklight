/// One styled stretch of source. Spans can nest: bold in a heading is a `.strong`
/// inside a `.heading`, listed after it.
public struct HighlightSpan: Equatable, Sendable {
    public enum Style: Hashable, Sendable {
        case heading(Int)
        /// Markdown punctuation: `**`, `#`, fences, table pipes.
        case syntax
        case strong, emphasis, strikethrough
        case code, codeBlock
        case link, url, image
        case listMarker, quoteMarker
        case rule, html, escape, frontMatter
        /// A byte that isn't valid UTF-8.
        case invalidByte
    }

    public let range: Range<Int>
    public let style: Style

    public init(_ range: Range<Int>, _ style: Style) {
        self.range = range
        self.style = style
    }
}

/// Source-pane highlighting, from the same parse the other pane will use, so the
/// panes can't disagree about what's what.
public enum Highlighter {
    public static func spans(_ document: ParsedDocument) -> [HighlightSpan] {
        var walker = Walker(u: document.units)
        for block in document.root.children { walker.visit(block) }
        walker.addReferenceDefinitions(document)
        walker.addInvalidBytes()
        return walker.out.filter { !$0.range.isEmpty }
    }

    private struct Walker {
        let u: [UInt16]
        var out: [HighlightSpan] = []

        mutating func add(_ range: Range<Int>, _ style: HighlightSpan.Style) {
            out.append(HighlightSpan(range, style))
        }

        mutating func visit(_ block: Block) {
            switch block.kind {
            case .document:
                break
            case .frontMatter:
                add(block.range, .frontMatter)
            case .heading(let level):
                add(block.range, .heading(level))
                if block.content.lowerBound > block.range.lowerBound {
                    add(block.range.lowerBound..<block.content.lowerBound, .syntax)
                }
                if block.content.upperBound < block.range.upperBound {
                    add(block.content.upperBound..<block.range.upperBound, .syntax)
                }
                inlines(block)
            case .paragraph, .cell:
                inlines(block)
            case .quote:
                quoteMarkers(block)
            case .item(let checked):
                let end = markerEnd(block)
                add(block.range.lowerBound..<end, .listMarker)
                if checked != nil { add(end..<u.count.clampedMin(end + 3), .listMarker) }
            case .code:
                add(block.range, .codeBlock)
                fences(block)
            case .html:
                add(block.range, .html)
            case .rule:
                add(block.range, .rule)
            case .table:
                delimiterRow(block)
            case .row:
                pipes(block)
            case .list:
                break
            }
            for child in block.children { visit(child) }
        }

        private func markerEnd(_ item: Block) -> Int {
            var i = item.range.lowerBound
            while let unit = u.at(i), (0x30...0x39).contains(unit) { i += 1 }
            i += 1 // the bullet, or the . or ) after the digits
            let afterMarker = i
            while u.at(i) == 0x20 { i += 1 }
            return (i - afterMarker) > 4 || u.at(i) == nil ? afterMarker : i
        }

        private mutating func quoteMarkers(_ quote: Block) {
            let outer = quote.quoteDepth
            var line = quote.range.lowerBound
            var isFirst = true
            while line < quote.range.upperBound {
                var i = line
                var seen = isFirst ? outer : 0
                while true {
                    while let unit = u.at(i), unit.isSpaceOrTab { i += 1 }
                    guard u.at(i) == 0x3E else { break }
                    if seen == outer {
                        add(i..<i + 1, .quoteMarker)
                        break
                    }
                    seen += 1
                    i += 1
                }
                isFirst = false
                let end = u.lineEnd(from: line)
                guard end < u.count else { break }
                line = u.afterLineBreak(end)
            }
        }

        private mutating func fences(_ code: Block) {
            guard !code.isOpaque else { return }
            var s = code.range.lowerBound
            while let unit = u.at(s), unit.isSpaceOrTab { s += 1 }
            guard u.at(s) == 0x60 || u.at(s) == 0x7E else { return }
            add(code.range.lowerBound..<u.lineEnd(from: code.range.lowerBound), .syntax)
            var last = code.range.upperBound
            if last > 0, u.at(last - 1)?.isLineBreak == true { last -= 1 }
            var lineStart = last
            while lineStart > 0, u.at(lineStart - 1)?.isLineBreak == false { lineStart -= 1 }
            let line = u[lineStart..<last]
            let fence = line.drop { $0.isSpaceOrTab || $0 == 0x3E }
            if lineStart > code.range.lowerBound, let char = fence.first, char == u[s], fence.count >= 3,
               fence.allSatisfy({ $0 == char || $0.isSpaceOrTab }) {
                add(lineStart..<last, .syntax)
            }
        }

        private mutating func delimiterRow(_ table: Block) {
            guard let head = table.children.first else { return }
            let start = u.afterLineBreak(u.lineEnd(from: head.range.upperBound))
            add(start..<u.lineEnd(from: start), .syntax)
        }

        private mutating func pipes(_ row: Block) {
            var i = row.range.lowerBound
            var cells = row.children.makeIterator()
            var cell = cells.next()
            while i < row.range.upperBound {
                if let c = cell, i >= c.content.upperBound, i >= c.content.lowerBound { cell = cells.next() }
                if let c = cell, c.content.contains(i) {
                    i = c.content.upperBound
                    continue
                }
                if u[i] == 0x7C { add(i..<i + 1, .syntax) }
                i += 1
            }
        }

        private mutating func inlines(_ block: Block) {
            guard !block.isOpaque else { return }
            for inline in block.inlines { visit(inline, in: block) }
        }

        private mutating func visit(_ inline: Inline, in block: Block) {
            switch inline.kind {
            case .run:
                for atom in block.atoms[inline.atoms] where atom.kind == .text && atom.range.count > 1 {
                    add(atom.range, .escape)
                }
            case .image:
                add(inline.range, .image)
            case .html:
                add(inline.range, .html)
            case .mark(let mark):
                let openEnd = inline.range.lowerBound + mark.open.count
                let closeStart = inline.range.upperBound - mark.close.count
                switch mark.kind {
                case .strong: add(inline.range, .strong)
                case .emphasis: add(inline.range, .emphasis)
                case .strikethrough: add(inline.range, .strikethrough)
                case .code: add(inline.range, .code)
                case .link:
                    add(openEnd..<closeStart, .link)
                    if mark.close.first == 0x5D, mark.close.count > 1 {
                        add(closeStart + 1..<inline.range.upperBound, .url)
                    }
                }
                if !mark.open.isEmpty { add(inline.range.lowerBound..<openEnd, .syntax) }
                for child in inline.children { visit(child, in: block) }
                if !mark.close.isEmpty { add(closeStart..<inline.range.upperBound, .syntax) }
            }
        }

        /// `[label]: /url` lines produce no AST node, so they're found in the gaps.
        mutating func addReferenceDefinitions(_ document: ParsedDocument) {
            var gapStart = 0
            for block in document.root.children + [Block(kind: .document, range: u.count..<u.count)] {
                var line = gapStart
                while line < block.range.lowerBound {
                    let end = u.lineEnd(from: line)
                    var i = line
                    while u.at(i) == 0x20 { i += 1 }
                    if u.at(i) == 0x5B, let close = u[i..<end].firstIndex(of: 0x5D), u.at(close + 1) == 0x3A {
                        add(i..<close + 2, .syntax)
                        add(close + 2..<end, .url)
                    }
                    guard end < u.count else { break }
                    line = u.afterLineBreak(end)
                }
                gapStart = Swift.max(gapStart, block.range.upperBound)
            }
        }

        /// U+10FF80...U+10FFFF, as a surrogate pair: U+DBFF then U+DF80...U+DFFF.
        mutating func addInvalidBytes() {
            var i = 0
            while i + 1 < u.count {
                if u[i] == 0xDBFF, (0xDF80...0xDFFF).contains(u[i + 1]) {
                    add(i..<i + 2, .invalidByte)
                    i += 2
                } else {
                    i += 1
                }
            }
        }
    }
}

private extension Int {
    /// `self`, or `limit` if it's smaller.
    func clampedMin(_ limit: Int) -> Int { Swift.min(self, limit) }
}
