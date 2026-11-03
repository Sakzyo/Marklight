import Foundation
import Markdown

/// What a node's source slice should look like. Returns nil when the slice is
/// right, or a reason when it isn't. Reasons starting with "~" are known,
/// predictable deviations rather than wrong ranges.
func expectation(for node: Markup, slice: String) -> String? {
    let s = slice
    let lead = String(s.drop { $0 == " " })
    let lines = s.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }

    switch node {
    case let heading as Heading:
        if lead.hasPrefix("#") {
            let hashes = lead.prefix { $0 == "#" }.count
            return hashes == heading.level ? nil : "ATX with \(hashes) #, level \(heading.level)"
        }
        let underline = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let char: Character = heading.level == 1 ? "=" : "-"
        return !underline.isEmpty && underline.allSatisfy({ $0 == char }) ? nil : "setext underline missing"

    case is Strong:
        return (s.hasPrefix("**") && s.hasSuffix("**")) || (s.hasPrefix("__") && s.hasSuffix("__"))
            ? nil : "not wrapped in ** or __"

    case is Emphasis:
        guard let first = s.first, let last = s.last, "*_".contains(first), first == last, s.count >= 2 else {
            return "not wrapped in * or _"
        }
        return nil

    case is Strikethrough:
        return s.hasPrefix("~") && s.hasSuffix("~") ? nil : "not wrapped in ~"

    case let code as InlineCode:
        let ticks = s.prefix { $0 == "`" }.count
        guard ticks > 0, s.hasSuffix(String(repeating: "`", count: ticks)),
              !s.dropLast(ticks).hasSuffix("`") || s.count == ticks * 2 else { return "backtick fences don't match" }
        var inner = String(s.dropFirst(ticks).dropLast(ticks))
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if inner.hasPrefix(" "), inner.hasSuffix(" "), inner.contains(where: { $0 != " " }) {
            inner = String(inner.dropFirst().dropLast())
        }
        return inner == code.code ? nil : "content \(inner.debugDescription) vs code \(code.code.debugDescription)"

    case let image as Image:
        guard s.hasPrefix("![") else { return "doesn't start with ![" }
        return s.hasSuffix(")") || s.hasSuffix("]") ? nil : "doesn't end with ) or ] (source \(image.source ?? "nil"))"

    case let link as Link:
        if s.hasPrefix("[") { return s.hasSuffix(")") || s.hasSuffix("]") ? nil : "doesn't end with ) or ]" }
        if s.hasPrefix("<") { return s.hasSuffix(">") ? nil : "autolink doesn't end with >" }
        // GFM literal autolink: the slice is the visible text.
        return s == link.plainText ? nil : "literal autolink slice vs text \(link.plainText.debugDescription)"

    case let text as Text:
        if s == text.string || unescape(s) == text.string { return nil }
        if s.hasPrefix(text.string), s.dropFirst(text.string.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
            return "~ range includes trailing whitespace the text drops"
        }
        if s.contains("&"), s.contains(";") { return "~ entity not decoded by this checker" }
        return "text \(text.string.debugDescription)"

    case let code as CodeBlock:
        if lead.hasPrefix("```") || lead.hasPrefix("~~~") {
            let fenceChar = lead.first!
            let fenceLength = lead.prefix { $0 == fenceChar }.count
            // Containers strip indentation from each code line, so compare line by line.
            for line in code.code.split(separator: "\n") where !s.contains(line.trimmingCharacters(in: .whitespaces)) {
                return "code line \(line.debugDescription) not inside slice"
            }
            let closing = lines.last(where: { !$0.isEmpty })?.trimmingCharacters(in: .whitespaces) ?? ""
            let closed = closing.count >= fenceLength && closing.allSatisfy { $0 == fenceChar } && lines.count > 1
            return closed || !s.hasSuffix("\n") ? nil : "closing fence not included"
        }
        // Indented: every code line must appear in the slice.
        for line in code.code.split(separator: "\n") where !s.contains(line) { return "indented line \(line.debugDescription) missing" }
        return nil

    case let html as HTMLBlock:
        let raw = html.rawHTML.trimmingCharacters(in: .newlines)
        if s.trimmingCharacters(in: .newlines) == raw { return nil }
        return s.trimmingCharacters(in: .newlines) == raw.trimmingCharacters(in: .whitespaces)
            ? "~ range starts after the block's leading indentation" : "html \(html.rawHTML.debugDescription)"

    case let html as InlineHTML:
        return s == html.rawHTML ? nil : "html \(html.rawHTML.debugDescription)"

    case is LineBreak where slice.isEmpty, is SoftBreak where slice.isEmpty:
        return nil
    case is LineBreak:
        let core = s.trimmingCharacters(in: .newlines)
        return core == "\\" || (core.count >= 2 && core.allSatisfy { $0 == " " }) ? nil : "not a hard-break marker"

    case is SoftBreak:
        return s.allSatisfy { $0.isNewline } && !s.isEmpty ? nil : "not just a line ending"

    case is ThematicBreak:
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.allSatisfy({ "-*_ \t".contains($0) }) ? nil : "not a rule"

    case is BlockQuote:
        return lead.hasPrefix(">") ? nil : "doesn't start with >"

    case is ListItem:
        return lead.range(of: #"^([-+*]|\d{1,9}[.)])([ \t]|$)"#, options: .regularExpression) != nil ? nil : "doesn't start with a list marker"

    case is UnorderedList, is OrderedList:
        return lead.range(of: #"^([-+*]|\d{1,9}[.)])"#, options: .regularExpression) != nil ? nil : "doesn't start with a list marker"

    case is Paragraph:
        return s.first?.isWhitespace == false && s.last?.isNewline == false ? nil : "leading space or trailing newline"

    case is Table:
        return lines.first?.contains("|") == true ? nil : "first line has no |"

    case is Table.Head, is Table.Row:
        return lines.count == 1 || (lines.count == 2 && lines[1].isEmpty) ? nil : "spans \(lines.count) lines"

    case let cell as Table.Cell:
        if cell.childCount == 0, s.hasSuffix("|") { return "empty cell range includes the closing pipe" }
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return cell.childCount == 0 ? nil : "empty slice for non-empty cell" }
        return unescape(t.replacingOccurrences(of: "\\|", with: "|")).contains(cell.plainText) || t.contains(cell.plainText)
            ? nil : "cell slice vs text \(cell.plainText.debugDescription)"

    default:
        return nil
    }
}

/// Undo backslash escapes and the entities used in the fixtures.
func unescape(_ s: String) -> String {
    var out = ""
    var iterator = s.makeIterator()
    while let c = iterator.next() {
        if c == "\\", let next = iterator.next() {
            if next.isASCII, next.isPunctuation || next.isSymbol { out.append(next) } else { out.append(c); out.append(next) }
        } else {
            out.append(c)
        }
    }
    for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&copy;", "©"), ("&#169;", "©"), ("&#xA9;", "©"), ("&nbsp;", "\u{A0}"), ("&quot;", "\"")] {
        out = out.replacingOccurrences(of: entity, with: value)
    }
    return out
}
