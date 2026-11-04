import Foundation
import Testing
@testable import MarklightCore

@Suite("Incremental reference context")
struct ReferenceContextTests {
    private let filler = (0..<30).map { "Paragraph \($0)\n\n" }.joined()
    private func check(_ text: String, _ needle: String, _ new: String, local: Bool) throws {
        let s = text as NSString, r = s.range(of: needle)
        try #require(r.location != NSNotFound)
        let p = Patch(range: r.location..<NSMaxRange(r), replacement: Array(new.utf16), origin: .rendered)
        var units = Array(text.utf16)
        let candidate = IncrementalDocument(units: units).applying(p)
        units.replaceSubrange(p.range, with: p.replacement)
        #expect(candidate.usedFullParse == !local, "\(needle.debugDescription) → \(new.debugDescription)")
        try checkAgainstFullParse(candidate, expected: units, context: "\(needle) → \(new)")
    }

    @Test func distantDefinitions() throws {
        let doc = filler + "Target [a][ref]\n\n" + filler + "[ref]: /first\n[REF]: /duplicate\n"
        try check(doc, "Target", "Edited", local: true)
        try check(doc, "[a][ref]", "[b][REF]", local: true)
        try check(doc, "[a][ref]", "[a][none]", local: true)
        try check(doc, "/first", "/new", local: false)
        try check(doc, "[ref]:", "[other]:", local: false)
        try check(doc, "[ref]: /first\n", "", local: false)
        try check(doc, "Target [a][ref]", "[new]: /url", local: false)
        try check(filler + "[unused]: /url\n", "Paragraph 12", "Mid sentence", local: true)
    }

    @Test func crossingTheBudgetInEitherDirection() throws {
        let url = "/" + String(repeating: "a", count: 999)
        let prefix = "[r]: " + url + "\n\n" + filler
        let suffix = filler + "Last [r]."
        for (from, to) in [(101, 95), (95, 101)] {
            let old = String(repeating: "[r] ", count: from)
            let new = String(repeating: "[r] ", count: to)
            try check(prefix + old + "\n\n" + suffix, old, new, local: false)
        }
    }

    @Test func ambiguousSyntaxAndBudget() throws {
        let edited = "Target [a]\n\n" + filler
        for definitions in ["[a]: /x\n  \"title\"", "  [a]: /x", "> [a]: /x", "[a]:\n/x",
                            "[a]: /x?a&amp;b", "[a]: /x\ntext", "```\n[a]: /x\n```"] {
            try check(edited + definitions, "Target", "Other", local: false)
        }
        let use = String(repeating: "[a] ", count: 1600)
        let url = "/" + String(repeating: "p", count: 100)
        try check(edited + use + "\n\n[a]: " + url, "Target", "Other", local: false)
        // The edited single top-level node needs its remote definition even
        // though the parser emits no block at the definition's position.
        try check("[x]: /url\n\nTarget [x]", "Target", "Other", local: true)
        try check("\u{FEFF}Target [x]\n\n" + filler + "[x]: /url", "Target", "Other", local: false)
    }
}
