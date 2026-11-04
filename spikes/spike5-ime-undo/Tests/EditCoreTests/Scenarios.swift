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
        // Undoing everything gives the original bytes; redoing gives the result.
        let result = editor.text
        while editor.canUndo { editor.undo() }
        #expect(editor.text.utf8.elementsEqual(text.utf8), "undo")
        while editor.canRedo { editor.redo() }
        #expect(editor.text.utf8.elementsEqual(result.utf8), "redo")
        #expect(Outline.of(editor.doc.root) == s.outline, "structure after redo")
    }

    /// Keystrokes with a fake clock, so grouping can be tested without waiting.
    final class Typist {
        let editor: Editor
        var now = 0.0
        var caret = 0
        init(_ text: String) {
            editor = Editor(text: text)
            editor.clock = { [unowned self] in now }
        }
        func type(_ s: String, gap: Double = 0.1) {
            for ch in s {
                now += gap
                caret = editor.perform(.insert(String(ch), caret..<caret)).caret
            }
        }
        func backspace(_ n: Int, gap: Double = 0.1) {
            for _ in 0..<n {
                now += gap
                caret = editor.perform(.delete(caret..<caret, backward: true)).caret
            }
        }
    }

    @Test func typingGroupsByWord() {
        let t = Typist("x \n")
        t.caret = 2
        t.type("one two three")
        #expect(t.editor.text == "x one two three\n")
        t.editor.undo()
        #expect(t.editor.text == "x one two \n")
        t.editor.undo()
        #expect(t.editor.text == "x one \n")
        t.editor.undo()
        #expect(t.editor.text == "x \n")
        #expect(!t.editor.canUndo)
    }

    @Test func aPauseStartsANewStep() {
        let t = Typist("x\n")
        t.caret = 1
        t.type("ab")
        t.type("cd", gap: 2)
        t.editor.undo()
        #expect(t.editor.text == "xabc\n")
        t.editor.undo()
        #expect(t.editor.text == "xab\n")
        t.editor.undo()
        #expect(t.editor.text == "x\n")
    }

    @Test func backspaceRunsGroup() {
        let t = Typist("hello\n")
        t.caret = 5
        t.backspace(3)
        #expect(t.editor.text == "he\n")
        let s = t.editor.undo()
        #expect(t.editor.text == "hello\n")
        #expect(s?.selection == 5..<5)
    }

    @Test func movingTheCaretStartsANewStep() {
        let t = Typist("abcd\n")
        t.caret = 1
        t.type("x")
        t.caret = 4
        t.type("y")
        t.editor.undo()
        #expect(t.editor.text == "axbcd\n")
    }

    @Test func structuralEditsAreOwnSteps() {
        let t = Typist("ab\n")
        t.caret = 2
        t.type("c")
        t.caret = t.editor.perform(.enter(t.caret..<t.caret)).caret
        t.type("d")
        t.editor.undo()
        #expect(t.editor.text == "abc\n\n\n")
        t.editor.undo()
        #expect(t.editor.text == "abc\n")
        t.editor.undo()
        #expect(t.editor.text == "ab\n")
    }

    @Test func undoRestoresAPendingParagraph() {
        let e = Editor(text: "ab\n")
        let enter = e.perform(.enter(2..<2))
        #expect(e.pending == enter.caret)
        e.undo()
        #expect(e.pending == nil)
        e.redo()
        #expect(e.pending == enter.caret)
        let typed = e.perform(.insert("c", enter.caret..<enter.caret))
        #expect(e.text == "ab\n\nc\n")
        #expect(typed.caret == enter.caret + 1)
    }

    @Test func aNewEditClearsRedo() {
        let e = Editor(text: "ab\n")
        e.perform(.insert("x", 1..<1))
        e.undo()
        #expect(e.canRedo)
        e.perform(.insert("y", 1..<1))
        #expect(!e.canRedo)
    }

    @Test func undoCrossesPanes() {
        let e = Editor(text: "ab\n")
        e.perform(.insert("r", 1..<1))
        e.sealUndoStep()
        e.applyExternal(0..<0, Array("s".utf16))
        #expect(e.text == "sarb\n")
        e.undo()
        #expect(e.text == "arb\n")
        e.undo()
        #expect(e.text == "ab\n")
        e.redo()
        e.redo()
        #expect(e.text == "sarb\n")
    }

    @Test func patchIsMinimal() {
        let e = Editor(text: "one **two** three\n\nnext\n")
        let o = e.perform(.insert("X", 9..<9))
        #expect(o.patch?.range == 9..<9)
        #expect(String(decoding: o.patch?.replacement ?? [], as: UTF16.self) == "X")
    }
}
