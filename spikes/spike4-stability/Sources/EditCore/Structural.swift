import Foundation

/// Block-path edits: re-serialize only the affected blocks. `perform` turns the
/// result into one minimal patch, so untouched text can't change.
extension Editor {
    private func trimEnd(_ atoms: ArraySlice<Atom>) -> [Atom] {
        var a = Array(atoms)
        while let last = a.last, last.isSpace { a.removeLast() }
        return a
    }

    private func trimStart(_ atoms: ArraySlice<Atom>) -> [Atom] {
        Array(atoms.drop { $0.isSpace })
    }

    private func written(_ atoms: [Atom], caret: Int? = nil, at: UnsafeMutablePointer<Int>? = nil, leaf: Block? = nil) -> [UInt16] {
        var options = WriteOptions()
        if let leaf {
            options.eol = eol(at: leaf.content.lowerBound)
            options.linePrefix = linePrefix(leaf)
        }
        return Serializer.write(Serializer.normalize(atoms), source: units, options: options, caret: caret, caretOffset: at)
    }

    private func setPending(_ offset: Int) {
        pendingOverride = offset
    }

    // MARK: - Enter

    func enter(_ range: Range<Int>, pending: Int?) throws {
        if !range.isEmpty {
            try delete(range, backward: true, pending: nil)
            return try enter(caret..<caret, pending: pendingOverride)
        }
        let offset = range.lowerBound
        if offset == pending { return try enterOnPending(offset) }
        if let item = emptyItem(at: offset) { return try exitItem(item) }
        guard let target = leaf(at: offset) else { throw Refusal("no text block at \(offset)") }
        guard !target.opaque else { throw Refusal("leaf could not be anchored") }
        switch target.kind {
        case .code:
            try editCode(target, offset..<offset, String(decoding: eol(at: offset) + codeIndent(target, offset), as: UTF16.self))
        case .cell:
            throw Refusal("Enter does nothing in a table cell")
        case .heading:
            try splitHeading(target, offset)
        default:
            try splitParagraph(target, offset)
        }
    }

    /// A code line's own indent, which an indented block depends on.
    private func codeIndent(_ code: Block, _ offset: Int) -> [UInt16] {
        let l = lineStart(offset)
        let first = code.atoms.first { ($0.range?.lowerBound ?? -1) >= l }?.range?.lowerBound
        return first.map { Array(units[l..<min($0, offset)]) } ?? linePrefix(code)
    }

    private func splitParagraph(_ target: Block, _ offset: Int) throws {
        let i = atomIndex(target, offset)
        if let item = target.parent, case .item = item.kind, item.children.first === target {
            return try splitItem(target, item, i)
        }
        let (left, right) = linkSafe(trimEnd(target.atoms[..<i]), trimStart(target.atoms[i...]))
        let p = linePrefix(target)
        let e = eol(at: offset)
        let sep = e + blank(p) + e + p
        let leftText = written(left, leaf: target)
        var rightCaret = 0
        let rightText = written(right, caret: 0, at: &rightCaret, leaf: target)
        let new = leftText + sep + rightText
        let base = target.content.lowerBound
        commit(replacing(target.content, with: new), caret: base + leftText.count + sep.count + rightCaret)
        path = .block
        if right.isEmpty { setPending(base + leftText.count + sep.count) }
        else if left.isEmpty { setPending(base) }
    }

    private func splitHeading(_ target: Block, _ offset: Int) throws {
        let i = atomIndex(target, offset)
        let left = trimEnd(target.atoms[..<i])
        let right = trimStart(target.atoms[i...])
        let e = eol(at: offset)
        let p = linePrefix(target)
        let sep = e + blank(p) + e + p
        let suffix = Array(units[target.content.upperBound..<max(target.content.upperBound, target.range.upperBound)])
        let base = target.content.lowerBound
        if left.isEmpty {
            // Caret at the start: open a paragraph above.
            let at = target.range.lowerBound
            commit(replacing(at..<at, with: sep), caret: at + sep.count + (base - at))
            setPending(at)
            path = .block
            return
        }
        let (splitLeft, splitRight) = linkSafe(left, right)
        let leftText = written(splitLeft, leaf: target)
        let rightText = written(splitRight, leaf: target)
        let head = leftText + suffix + sep
        let end = max(target.content.upperBound, target.range.upperBound)
        // A heading can sit right on top of text; a paragraph can't.
        let gap = right.isEmpty || !nextLineHasText(end) ? [] : e + blank(p)
        commit(replacing(base..<end, with: head + rightText + gap), caret: base + head.count)
        path = .block
        if right.isEmpty { setPending(base + head.count) }
    }

    func nextLineHasText(_ offset: Int) -> Bool {
        var i = lineEnd(offset)
        guard i < units.count else { return false }
        i += units[i] == 0x0D && units[safe: i + 1] == 0x0A ? 2 : 1
        return i < units.count && !lineIsBlank(i)
    }

    func previousLineHasText(_ offset: Int) -> Bool {
        var i = lineStart(offset)
        guard i > 0 else { return false }
        i -= 1
        if units[i] == 0x0A, i > 0, units[i - 1] == 0x0D { i -= 1 }
        return !lineIsBlank(lineStart(i))
    }

    private func lineIsBlank(_ start: Int) -> Bool {
        units[start..<lineEnd(start)].allSatisfy { $0.isSpaceOrTab || $0 == 0x3E }
    }

    /// Splitting a link that has no target of its own (an autolink or `[shortcut]`)
    /// would break both halves, so give each half an explicit target.
    private func linkSafe(_ left: [Atom], _ right: [Atom]) -> ([Atom], [Atom]) {
        guard let last = left.last, let first = right.first else { return (left, right) }
        var l = left, r = right
        for m in last.marks where first.marks.contains(m) {
            guard case .link(let dest) = m.kind else { continue }
            let close = String(decoding: m.close, as: UTF16.self)
            if m.open == [0x5B], close.count > 2, !close.hasPrefix("][]") { continue } // keeps its own tail
            nextMark += 1
            let inline = Mark(kind: m.kind, id: nextMark, open: [0x5B], close: Array("](\(dest))".utf16))
            for i in l.indices { l[i].marks = l[i].marks.map { $0 == m ? inline : $0 } }
            for i in r.indices { r[i].marks = r[i].marks.map { $0 == m ? inline : $0 } }
        }
        return (l, r)
    }

    private func number(of item: Block) -> Int? {
        var i = item.range.lowerBound
        var n = 0
        var digits = 0
        while let u = units[safe: i], (0x30...0x39).contains(u) {
            n = n * 10 + Int(u - 0x30)
            digits += 1
            i += 1
        }
        return digits > 0 ? n : nil
    }

    private func markerText(_ item: Block, number n: Int?) -> [UInt16] {
        let w = markerWidth(item)
        let raw = Array(units[item.range.lowerBound..<min(item.range.lowerBound + w, units.count)])
        var marker = raw
        if let n, let old = number(of: item) {
            marker = Array(String(n).utf16) + raw.dropFirst(String(old).utf16.count)
        }
        if marker.last != 0x20 { marker.append(0x20) }
        if case .item(.some) = item.kind { marker += Array("[ ] ".utf16) }
        return marker
    }

    private func itemPrefix(_ item: Block) -> [UInt16] {
        let p = linePrefix(item)
        let col = item.range.lowerBound - lineStart(item.range.lowerBound)
        return p + [UInt16](repeating: 0x20, count: max(0, col - p.count))
    }

    private func isLoose(_ list: Block) -> Bool {
        guard list.children.count > 1 else { return false }
        // Item ranges can include trailing blank lines, so measure from the content.
        let end = list.children[0].children.last?.range.upperBound ?? list.children[0].range.upperBound
        let gap = units[end..<list.children[1].range.lowerBound]
        return gap.filter { $0 == 0x0A || $0 == 0x0D }.count >= 2 + (gap.contains(0x0D) && gap.contains(0x0A) ? 2 : 0)
    }

    private func splitItem(_ target: Block, _ item: Block, _ i: Int) throws {
        guard let list = item.parent, let idx = list.children.firstIndex(where: { $0 === item }) else { throw Refusal("orphan item") }
        let (left, right) = linkSafe(trimEnd(target.atoms[..<i]), trimStart(target.atoms[i...]))
        let e = eol(at: target.content.lowerBound)

        var next: Int? = nil
        var renumber = false
        if case .list(true, _) = list.kind, let n = number(of: item) {
            let numbers = list.children.compactMap { number(of: $0) }
            let sequential = zip(numbers, numbers.dropFirst()).allSatisfy { $1 == $0 + 1 }
            let allSame = numbers.count > 1 && Set(numbers).count == 1
            next = allSame ? n : n + 1
            renumber = sequential && !allSame
        }
        let linePre = itemPrefix(item)
        let sep = e + (isLoose(list) ? blank(linePre) + e : []) + linePre + markerText(item, number: next)

        var u = units
        if renumber, let start = next {
            for (k, later) in list.children.enumerated().reversed() where k > idx {
                guard let old = number(of: later) else { continue }
                let lo = later.range.lowerBound
                u.replaceSubrange(lo..<(lo + String(old).utf16.count), with: Array(String(start + (k - idx)).utf16))
            }
        }
        let leftText = written(left, leaf: target)
        var rightCaret = 0
        let rightText = written(right, caret: 0, at: &rightCaret, leaf: target)
        u.replaceSubrange(target.content, with: leftText + sep + rightText)
        commit(u, caret: target.content.lowerBound + leftText.count + sep.count + rightCaret)
        path = .block
    }

    /// Enter or Backspace on an empty item: leave the list, or outdent if nested.
    func exitItem(_ item: Block) throws {
        guard let list = item.parent, let idx = list.children.firstIndex(where: { $0 === item }) else { throw Refusal("orphan item") }
        let l = lineStart(item.range.lowerBound)
        let end = lineEnd(item.range.lowerBound)
        if let parent = list.parent, case .item = parent.kind {
            let new = itemPrefix(parent) + markerText(parent, number: number(of: parent).map { $0 + 1 })
            commit(replacing(l..<end, with: new), caret: l + new.count)
            path = .block
            return
        }
        let p = linePrefix(list)
        let b = blank(p)
        let e = eol(at: l)
        let hasNext = idx + 1 < list.children.count
        var new: [UInt16]
        var at: Int
        if idx == 0 {
            new = p + (hasNext ? e + b : [])
            at = l + p.count
        } else {
            new = b + e + p + (hasNext ? e + b : [])
            at = l + b.count + e.count + p.count
        }
        if idx == 0, !hasNext { new = p; at = l + p.count }
        commit(replacing(l..<end, with: new), caret: at)
        setPending(at)
        path = .block
    }

    private func enterOnPending(_ offset: Int) throws {
        let l = lineStart(offset)
        let line = units[l..<offset]
        guard line.contains(0x3E), l > 0 else {
            caret = offset
            setPending(offset)
            return
        }
        // Enter on an empty line in a quote leaves the quote.
        var previous = l - 1
        if units[previous] == 0x0A, previous > 0, units[previous - 1] == 0x0D { previous -= 1 }
        let pl = lineStart(previous)
        let e = eol(at: offset)
        commit(replacing(pl..<offset, with: e), caret: pl + e.count)
        setPending(pl + e.count)
        path = .block
    }

    // MARK: - Backspace and forward delete at block edges

    func backspaceAtStart(_ target: Block) throws {
        caret = target.content.lowerBound
        guard !target.opaque else { throw Refusal("leaf could not be anchored") }
        switch target.kind {
        case .cell, .code:
            return
        case .heading:
            return try removeHeading(target, caretAt: target.content.lowerBound)
        default:
            break
        }
        if let parent = target.parent, parent.children.first === target {
            if case .item = parent.kind { return try liftItem(target, parent) }
            if parent.kind == .quote { return try liftQuote(target, parent) }
        }
        guard let previous = neighbour(of: target, step: -1) else { return }
        switch previous.kind {
        case .paragraph, .heading:
            try merge(previous, target)
        case .rule:
            let l = lineStart(previous.range.lowerBound)
            var end = lineEnd(previous.range.upperBound)
            while let u = units[safe: end], u.isLineBreak { end += 1 }
            let shift = end - l
            commit(replacing(l..<end, with: []), caret: target.content.lowerBound - shift)
            path = .block
        default:
            return // code, HTML, and tables keep their boundary
        }
    }

    func deleteAtEnd(_ target: Block) throws {
        caret = target.content.upperBound
        guard let next = neighbour(of: target, step: 1) else { return }
        switch (target.kind, next.kind) {
        case (.paragraph, .paragraph), (.heading, .paragraph), (.paragraph, .heading), (.heading, .heading):
            try merge(target, next)
        default:
            return
        }
    }

    private func neighbour(of block: Block, step: Int) -> Block? {
        var b = block
        while let parent = b.parent, let idx = parent.children.firstIndex(where: { $0 === b }) {
            let k = idx + step
            if parent.children.indices.contains(k) {
                var c = parent.children[k]
                while !c.children.isEmpty, !c.isLeaf {
                    c = step < 0 ? c.children.last! : c.children.first!
                }
                return c
            }
            if parent.kind == .document { return nil }
            b = parent
        }
        return nil
    }

    private func merge(_ a: Block, _ b: Block) throws {
        guard !a.opaque, !b.opaque else { throw Refusal("leaf could not be anchored") }
        let keep = trimEnd(a.atoms[...])
        var tail = b.atoms
        var suffix: [UInt16] = []
        var end = b.content.upperBound
        if case .heading = b.kind { end = max(end, b.range.upperBound) }
        if case .heading = a.kind {
            // A heading is one line (setext aside), and keeps its closing or underline.
            suffix = Array(units[a.content.upperBound..<max(a.content.upperBound, a.range.upperBound)])
            for k in tail.indices where tail[k].kind == .softBreak || tail[k].kind == .hardBreak {
                tail[k] = Atom(kind: .text, unit: 0x20, marks: tail[k].marks)
            }
        }
        var at = 0
        let text = written(keep + tail, caret: keep.count, at: &at, leaf: a)
        commit(replacing(a.content.lowerBound..<end, with: text + suffix), caret: a.content.lowerBound + at)
        path = .block
    }

    /// Turn the item's first paragraph into plain text, or outdent a nested item.
    private func liftItem(_ target: Block, _ item: Block) throws {
        guard let list = item.parent, let idx = list.children.firstIndex(where: { $0 === item }) else { throw Refusal("orphan item") }
        let l = lineStart(item.range.lowerBound)
        let width = markerWidth(item)
        let lastChildEnd = item.children.last?.range.upperBound ?? item.range.upperBound
        let lastLineEnd = lineEnd(max(item.range.lowerBound, lastChildEnd - 1))
        let keep = l..<item.range.lowerBound

        // De-indent each continuation line.
        var lines: [UInt16] = []
        var at = lineEnd(target.content.lowerBound) // the marker can sit on its own line
        lines += units[target.content.lowerBound..<at]
        while at < lastLineEnd {
            var next = at
            if units[next] == 0x0D, units[safe: next + 1] == 0x0A { next += 2 } else { next += 1 }
            lines += units[at..<next]
            let lineEndAt = lineEnd(next)
            var body = next
            let pre = linePrefix(item)
            body += min(pre.count, lineEndAt - body)
            var stripped = 0
            while stripped < width, units[safe: body] == 0x20 { body += 1; stripped += 1 }
            lines += units[next..<(next + min(pre.count, lineEndAt - next))]
            lines += units[body..<lineEndAt]
            at = lineEndAt
        }

        if let parentItem = list.parent, case .item = parentItem.kind {
            // Nested: drop one level of indent and keep the marker.
            let outer = itemPrefix(parentItem)
            let new = outer + Array(units[item.range.lowerBound..<target.content.lowerBound]) + lines
            let c = l + outer.count + (target.content.lowerBound - item.range.lowerBound)
            commit(replacing(l..<lastLineEnd, with: new), caret: c)
            path = .block
            return
        }
        let p = linePrefix(list)
        let b = blank(p)
        let e = eol(at: l)
        var new: [UInt16] = Array(units[keep])
        var c = l + keep.count
        if idx > 0 || previousLineHasText(l) {
            // The line above is text the lifted paragraph would run into.
            new = b + e + Array(units[keep])
            c = l + b.count + e.count + keep.count
        }
        new += lines
        if idx + 1 < list.children.count { new += e + b }
        commit(replacing(l..<lastLineEnd, with: new), caret: c)
        path = .block
    }

    private func liftQuote(_ target: Block, _ quote: Block) throws {
        let p = linePrefix(quote)
        let l = lineStart(target.range.lowerBound)
        let last = lineEnd(max(target.range.lowerBound, target.range.upperBound - 1))
        var out: [UInt16] = []
        var at = l
        var firstShift = 0
        while true {
            let end = lineEnd(at)
            var body = at
            while body < end, units[body].isSpaceOrTab { body += 1 }
            if units[safe: body] == 0x3E {
                body += 1
                if units[safe: body] == 0x20 { body += 1 }
                let before = Array(units[at..<min(at + p.count, body)])
                out += before
                if at == l { firstShift = body - at - before.count }
                out += units[body..<end]
            } else {
                out += units[at..<end]
            }
            if end >= last { break }
            var next = end
            if units[next] == 0x0D, units[safe: next + 1] == 0x0A { next += 2 } else { next += 1 }
            out += units[end..<next]
            at = next
        }
        var endRange = last
        if quote.children.count > 1 {
            // The blank > line after this paragraph has to become really blank.
            let e = eol(at: last)
            let nextLine = last + e.count
            let nextEnd = lineEnd(nextLine)
            let onlyQuote = units[nextLine..<nextEnd].allSatisfy { $0 == 0x3E || $0.isSpaceOrTab }
            if onlyQuote {
                out += e + blank(p)
                endRange = nextEnd
            }
        }
        commit(replacing(l..<endRange, with: out), caret: target.content.lowerBound - firstShift)
        path = .block
    }

    private func removeHeading(_ target: Block, caretAt: Int) throws {
        let isATX = target.content.lowerBound > target.range.lowerBound
        let suffixEnd = max(target.content.upperBound, target.range.upperBound)
        let e = eol(at: target.range.lowerBound)
        let b = blank(linePrefix(target))
        // Plain text would run into a neighbouring line that a heading kept apart.
        let textAfter = nextLineHasText(suffixEnd)
        let textBefore = previousLineHasText(target.range.lowerBound)
        var u = units
        u.replaceSubrange(target.content.upperBound..<suffixEnd, with: textAfter ? e + b : [])
        if isATX { u.replaceSubrange(target.range.lowerBound..<target.content.lowerBound, with: []) }
        var c = caretAt - (target.content.lowerBound - target.range.lowerBound)
        if textBefore {
            let at = lineStart(target.range.lowerBound)
            u.replaceSubrange(at..<at, with: b + e)
            c += b.count + e.count
        }
        commit(u, caret: c)
        path = .block
    }

    func removePending(_ offset: Int, backward: Bool) throws {
        var k = offset
        while k > 0, units[k - 1].isLineBreak || units[k - 1] == 0x20 || units[k - 1] == 0x3E { k -= 1 }
        commit(replacing(k..<offset, with: []), caret: k)
        path = .block
    }

    /// A selection that crosses blocks: keep the head of the first and the tail of the last.
    func deleteAcross(_ range: Range<Int>) throws {
        let leaves = doc.root.allLeaves()
        guard let first = leaves.first(where: { $0.content.upperBound >= range.lowerBound }),
              let last = leaves.last(where: { $0.content.lowerBound <= range.upperBound }), first !== last else {
            throw Refusal("selection has no text blocks")
        }
        for leaf in [first, last] {
            guard !leaf.opaque else { throw Refusal("leaf could not be anchored") }
            switch leaf.kind {
            case .cell, .code: throw Refusal("selection crosses a table or code block")
            default: break
            }
        }
        let i = atomIndex(first, range.lowerBound)
        let j = atomIndex(last, range.upperBound)
        let merged = Array(first.atoms[..<i]) + Array(last.atoms[j...])
        var at = 0
        let text = written(merged, caret: i, at: &at, leaf: first)
        var end = last.content.upperBound
        if case .heading = last.kind { end = max(end, last.range.upperBound) }
        var suffix: [UInt16] = []
        if case .heading = first.kind { suffix = Array(units[first.content.upperBound..<max(first.content.upperBound, first.range.upperBound)]) }
        let span = first.content.lowerBound..<end
        commit(replacing(span, with: text + suffix), caret: span.lowerBound + at)
        path = .block
        if merged.isEmpty, first.kind == .paragraph { setPending(span.lowerBound) }
    }

    // MARK: - Headings and line breaks

    func setHeading(_ level: Int, at offset: Int) throws {
        guard let target = leaf(at: offset) else { throw Refusal("no text block at \(offset)") }
        guard !target.opaque else { throw Refusal("leaf could not be anchored") }
        let hashes = [UInt16](repeating: 0x23, count: level) + [0x20]
        switch target.kind {
        case .paragraph:
            guard level > 0 else { caret = offset; return }
            var atoms = target.atoms
            for k in atoms.indices where atoms[k].kind == .softBreak || atoms[k].kind == .hardBreak {
                atoms[k] = Atom(kind: .text, unit: 0x20, marks: atoms[k].marks)
            }
            var candidate = replacing(target.content, with: written(atoms, leaf: target))
            candidate.replaceSubrange(target.content.lowerBound..<target.content.lowerBound, with: hashes)
            commit(candidate, caret: offset + hashes.count)
        case .heading(let current):
            guard level != current else { caret = offset; return }
            if level == 0 { return try removeHeading(target, caretAt: offset) }
            let isATX = target.content.lowerBound > target.range.lowerBound
            if isATX {
                let old = target.content.lowerBound - target.range.lowerBound
                commit(replacing(target.range.lowerBound..<target.content.lowerBound, with: hashes), caret: offset - old + hashes.count)
            } else if level <= 2 {
                let underline = lineStart(target.range.upperBound)..<target.range.upperBound
                let char: UInt16 = level == 1 ? 0x3D : 0x2D
                commit(replacing(underline, with: [UInt16](repeating: char, count: underline.count)), caret: offset)
            } else {
                var u = replacing(target.content.upperBound..<target.range.upperBound, with: [])
                u.replaceSubrange(target.content.lowerBound..<target.content.lowerBound, with: hashes)
                commit(u, caret: offset + hashes.count)
            }
        default:
            throw Refusal("only paragraphs and headings have a level")
        }
        path = .block
    }

    func lineBreak(_ range: Range<Int>) throws {
        guard range.isEmpty else {
            try delete(range, backward: true, pending: nil)
            return try lineBreak(caret..<caret)
        }
        guard let target = leaf(at: range.lowerBound) else { throw Refusal("no text block") }
        switch target.kind {
        case .paragraph:
            let i = atomIndex(target, range.lowerBound)
            guard i < target.atoms.count else { throw Refusal("a hard break can't end a paragraph") }
            var hard = Atom(kind: .hardBreak)
            hard.marks = marks(at: range.lowerBound, in: target, index: i)
            try editLeaf(target, Array(target.atoms[..<i]) + [hard] + Array(target.atoms[i...]), caret: i + 1)
        case .code:
            try enter(range, pending: nil)
        default:
            throw Refusal("no line breaks here")
        }
    }

    // MARK: - Paste

    private func splitPlain(_ text: String) -> [[String]] {
        let normal = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normal.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\n") }
    }

    func pastePlain(_ text: String, _ range: Range<Int>, pending: Int?) throws {
        if !range.isEmpty, leaf(at: range.lowerBound).map({ range.upperBound > $0.content.upperBound }) ?? true {
            try deleteAcross(range)
            return try pastePlain(text, caret..<caret, pending: pendingOverride)
        }
        let paragraphs = splitPlain(text)
        guard !paragraphs.isEmpty else { return }
        guard let target = leaf(at: range.lowerBound), range.lowerBound != pending else {
            guard paragraphs.count == 1, paragraphs[0].count == 1 else { throw Refusal("multi-line paste needs a text block") }
            return try insert(paragraphs[0][0], range, pending: pending)
        }
        if case .code = target.kind {
            let code = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: String(decoding: eol(at: range.lowerBound) + codeIndent(target, range.lowerBound), as: UTF16.self))
            return try editCode(target, range, code)
        }
        let i = atomIndex(target, range.lowerBound)
        let j = atomIndex(target, range.upperBound)
        let m = marks(at: range.lowerBound, in: target, index: i)
        func atoms(_ lines: [String], singleLine: Bool) -> [Atom] {
            var out: [Atom] = []
            for (k, line) in lines.enumerated() {
                if k > 0 { out.append(singleLine ? Atom(kind: .text, unit: 0x20, marks: m) : Atom(kind: .softBreak, marks: m)) }
                out += textAtoms(line, marks: m)
            }
            return out
        }
        var single = target.kind != .paragraph
        if case .heading = target.kind { single = true }
        if paragraphs.count == 1 || single {
            let new = atoms(Array(paragraphs.joined()), singleLine: single)
            return try editLeaf(target, Array(target.atoms[..<i]) + new + Array(target.atoms[j...]), caret: i + new.count)
        }
        try spliceParagraphs(target, i, j, paragraphs.map { atoms($0, singleLine: false) })
    }

    private func spliceParagraphs(_ target: Block, _ i: Int, _ j: Int, _ inserted: [[Atom]]) throws {
        var parts = inserted
        parts[0] = Array(target.atoms[..<i]) + parts[0]
        let lastCount = parts[parts.count - 1].count
        parts[parts.count - 1] += Array(target.atoms[j...])
        let p = linePrefix(target)
        let e = eol(at: target.content.lowerBound)
        let sep = e + blank(p) + e + p
        let expected = parts.map { Editor.plain($0) }
        let oldCount = doc.root.allLeaves().count
        var options = WriteOptions()
        options.eol = e
        options.linePrefix = p
        for escape in [WriteOptions.Escape.none, .inline, .block] {
            options.escape = escape
            var body: [UInt16] = []
            var c = 0
            for (k, part) in parts.enumerated() {
                if k > 0 { body += sep }
                var at = 0
                let isLast = k == parts.count - 1
                let w = Serializer.write(Serializer.normalize(part), source: units, options: options, caret: lastCount, caretOffset: &at)
                if isLast { c = body.count + at }
                body += w
            }
            let candidate = replacing(target.content, with: body)
            let parsed = DocModel(units: candidate)
            reparses += 1
            let leaves = parsed.root.allLeaves()
            let start = leaves.firstIndex { $0.content.lowerBound == target.content.lowerBound }
            if leaves.count == oldCount + parts.count - 1, let start, start + parts.count <= leaves.count,
               (0..<parts.count).allSatisfy({ Editor.plain(leaves[start + $0].atoms) == expected[$0] }) {
                commit(candidate, caret: target.content.lowerBound + c, doc: parsed)
                path = .block
                return
            }
        }
        throw Refusal("pasted text would not parse as paragraphs")
    }

    private func atoms(from runs: [PasteRun]) -> [Atom] {
        var out: [Atom] = []
        var active: [String: Mark] = [:]
        for run in runs {
            var wanted: [Mark] = []
            func use(_ key: String, _ make: () -> Mark) {
                let m = active[key] ?? make()
                active[key] = m
                wanted.append(m)
            }
            if let href = run.href {
                use("a:\(href)") {
                    nextMark += 1
                    return Mark(kind: .link(href), id: nextMark, open: [0x5B], close: Array("](\(href))".utf16))
                }
            }
            for name in run.marks {
                switch name {
                case "strong": use(name) { newMark(.strong) }
                case "em": use(name) { newMark(.em) }
                case "strike": use(name) { newMark(.strike) }
                case "code":
                    use(name) {
                        nextMark += 1
                        return Mark(kind: .code, id: nextMark, open: [0x60], close: [0x60])
                    }
                default: break
                }
            }
            for key in active.keys where !wanted.contains(active[key]!) { active[key] = nil }
            out += textAtoms(run.text, marks: wanted)
        }
        return out
    }

    func pasteRich(_ blocks: [PasteBlock], _ range: Range<Int>, pending: Int?) throws {
        guard !blocks.isEmpty else { return }
        if !range.isEmpty, leaf(at: range.lowerBound).map({ range.upperBound > $0.content.upperBound }) ?? true {
            try deleteAcross(range)
            return try pasteRich(blocks, caret..<caret, pending: pendingOverride)
        }
        guard let target = leaf(at: range.lowerBound), range.lowerBound != pending else {
            throw Refusal("rich paste needs a text block")
        }
        let i = atomIndex(target, range.lowerBound)
        let j = atomIndex(target, range.upperBound)
        if blocks.count == 1, blocks[0].kind == .paragraph {
            let new = atoms(from: blocks[0].runs)
            return try editLeaf(target, Array(target.atoms[..<i]) + new + Array(target.atoms[j...]), caret: i + new.count)
        }
        let p = linePrefix(target)
        let e = eol(at: target.content.lowerBound)
        var options = WriteOptions()
        options.escape = .inline
        var body = i > 0 ? Serializer.write(Serializer.normalize(trimEnd(target.atoms[..<i])), source: units, options: options) : []
        var previous: PasteBlock.Kind? = i > 0 ? .paragraph : nil
        for (k, block) in blocks.enumerated() {
            let inline = Serializer.write(Serializer.normalize(atoms(from: block.runs)), source: units, options: options)
            var line: [UInt16]
            switch block.kind {
            case .paragraph: line = inline
            case .heading(let n): line = [UInt16](repeating: 0x23, count: n) + [0x20] + inline
            case .bullet: line = Array("- ".utf16) + inline
            case .ordered: line = Array("1. ".utf16) + inline
            case .quote: line = Array("> ".utf16) + inline
            case .code:
                let code = Array(block.runs.map { $0.text }.joined().utf16)
                line = Array("```".utf16) + e + p + code + e + p + Array("```".utf16)
            }
            if k == 0, block.kind == .paragraph, i > 0 {
                body += inline
                continue
            }
            if let previous {
                let tight = previous == block.kind && (block.kind == .bullet || block.kind == .ordered)
                body += tight ? e + p : e + blank(p) + e + p
            }
            body += line
            previous = block.kind
        }
        let c = target.content.lowerBound + body.count
        if j < target.atoms.count {
            body += e + blank(p) + e + p
            body += Serializer.write(Serializer.normalize(trimStart(target.atoms[j...])), source: units, options: options)
        }
        commit(replacing(target.content, with: body), caret: c)
        path = .block
    }
}
