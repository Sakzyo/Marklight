import Markdown

/// Converts swift-markdown's (line, column) locations into absolute offsets.
///
/// Hypothesis under test: columns are 1-based UTF-8 byte offsets within the
/// line, and lines are split on LF, CRLF, and lone CR (as cmark does).
struct LineIndex {
    let utf8: [UInt8]
    /// UTF-8 offset where each line starts (index 0 is line 1).
    private(set) var lineStarts: [Int] = [0]
    /// UTF-16 offset for every UTF-8 offset that starts a scalar, plus the end.
    private var utf16At: [Int: Int] = [:]

    init(_ text: String) {
        utf8 = Array(text.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == 0x0D {
                if i + 1 < utf8.count, utf8[i + 1] == 0x0A { i += 1 }
                lineStarts.append(i + 1)
            } else if utf8[i] == 0x0A {
                lineStarts.append(i + 1)
            }
            i += 1
        }
        var u8 = 0, u16 = 0
        for scalar in text.unicodeScalars {
            utf16At[u8] = u16
            u8 += UTF8.width(scalar)
            u16 += UTF16.width(scalar)
        }
        utf16At[u8] = u16
    }

    func utf8Offset(_ location: SourceLocation) -> Int? {
        guard location.line >= 1, location.line <= lineStarts.count else { return nil }
        let offset = lineStarts[location.line - 1] + location.column - 1
        return offset <= utf8.count ? offset : nil
    }

    func utf8Range(_ range: SourceRange) -> Range<Int>? {
        guard let lo = utf8Offset(range.lowerBound), let hi = utf8Offset(range.upperBound), lo <= hi else { return nil }
        return lo..<hi
    }

    /// nil when the UTF-8 offset falls inside a multi-byte scalar.
    func utf16Offset(_ utf8Offset: Int) -> Int? { utf16At[utf8Offset] }

    func slice(_ range: Range<Int>) -> String {
        String(decoding: utf8[range], as: UTF8.self)
    }
}
