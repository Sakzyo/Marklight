import EditScenarios
import Foundation
import Testing
@testable import EditCore

extension Scenario: CustomTestStringConvertible {
    public var testDescription: String { name }
}

@Suite("Rendered edit to source patch")
struct ScenarioTests {
    @Test(arguments: allScenarios)
    func scenario(_ s: Scenario) {
        let (text, start) = parseMarkers(s.before)
        let (expected, expectedCaret) = parseMarkers(s.after)
        let editor = Editor(text: text)
        var selection = start
        var snapshots: [String] = [text]
        for action in s.actions { apply(action, editor, &selection, &snapshots) }
        var got: [UInt16] = editor.units
        got.insert(0x2038, at: min(selection.lowerBound, got.count))
        let gotMarked = String(decoding: got, as: UTF16.self)
        let outline = Outline.of(editor.doc.root)
        let ok = editor.text.utf8.elementsEqual(expected.utf8) && selection == expectedCaret && outline == s.outline
        #expect(ok, "\(s.name)  GOT \(gotMarked.debugDescription) \(outline)  WANT \(s.after.debugDescription) \(s.outline)")
        // Every edit undoes to the exact bytes before it.
        for snapshot in snapshots.reversed().dropFirst() {
            editor.undo()
            #expect(editor.text.utf8.elementsEqual(snapshot.utf8), "undo")
        }
    }

    @Test func patchIsMinimal() {
        let e = Editor(text: "one **two** three\n\nnext\n")
        let o = e.perform(.insert("X", 9..<9))
        #expect(o.patch?.range == 9..<9)
        #expect(String(decoding: o.patch?.replacement ?? [], as: UTF16.self) == "X")
    }
}
