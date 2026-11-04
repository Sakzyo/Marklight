import Foundation
import Testing
@testable import MarklightCore

private struct Scenario: Decodable {
    let before: String
    let inputType: String
    let data: String?
    let after: String
}

private func marked(_ text: String) -> (String, Range<Int>) {
    var source: [UInt16] = []
    var start = 0, end = 0
    for u in text.utf16 {
        switch u {
        case 0x2038: start = source.count; end = start
        case 0x27E6: start = source.count
        case 0x27E7: end = source.count
        default: source.append(u)
        }
    }
    return (String(decoding: source, as: UTF16.self), start..<end)
}

@Suite("Rendered leaf edits")
struct RenderedEditTests {
    @Test func editScenarios() throws {
        let url = Fixtures.directory.deletingLastPathComponent().appendingPathComponent("RenderedLeafScenarios.json")
        let scenarios = try JSONDecoder().decode([Scenario].self, from: Data(contentsOf: url))
        for s in scenarios {
            let (before, selection) = marked(s.before)
            let (after, caret) = marked(s.after)
            let buffer = Buffer(contentsOf: Data(before.utf8))
            let original = buffer.serialized()
            let doc = IncrementalDocument(units: buffer.units)
            let edit = try #require(BlockSerializer.edit(doc, inputType: s.inputType, data: s.data, selection: selection, target: nil, pending: nil), "\(s.before) \(s.inputType)")
            #expect(edit.caret == caret.lowerBound, "\(s.before)")
            try buffer.apply(edit.patch, selectionBefore: selection)
            #expect(buffer.serialized() == Data(after.utf8), "\(s.before)")
            try checkAgainstFullParse(edit.document, expected: Array(after.utf16), context: s.before)
            #expect(buffer.undo()?.selection == selection)
            #expect(buffer.serialized() == original)
        }
    }

    @Test func emptyAndRetype() throws {
        for (before, result) in [("a‸", "z"), ("top\n\na‸\n\nlast", "top\n\nz\n\nlast"), ("- a‸\n", "- z\n"), ("> a‸\n", "> z\n")] {
            let (text, selection) = marked(before)
            let empty = try #require(BlockSerializer.edit(.init(units: Array(text.utf16)), inputType: "deleteContentBackward", data: nil, selection: selection, target: nil, pending: nil), "\(before)")
            let again = try #require(BlockSerializer.edit(empty.document, inputType: "insertText", data: "z", selection: empty.caret..<empty.caret, target: nil, pending: empty.pending), "\(before)")
            #expect(again.document.units == Array(result.utf16))
        }
    }

    @Test func refusals() {
        for (input, type) in [("a‸b", "insertParagraph"), ("a‸b", "insertFromPaste"), ("a‸b", "formatBold"), ("a\n\n‸b", "deleteContentBackward"), ("a⟦b\n\nc⟧d", "deleteContentBackward"), ("```\nx‸\n```", "insertText"), ("| h‸ |\n|---|\n", "insertText"), ("<div>x‸</div>", "insertText"), ("a &a‸mp; b", "insertText")] {
            let (text, selection) = marked(input)
            let doc = IncrementalDocument(units: Array(text.utf16))
            #expect(BlockSerializer.edit(doc, inputType: type, data: "x", selection: selection, target: nil, pending: nil) == nil, "\(input) \(type)")
        }
    }
}
