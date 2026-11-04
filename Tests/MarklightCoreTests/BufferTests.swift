import Foundation
import Testing
@testable import MarklightCore

/// Keystrokes with a fake clock, so grouping can be tested without waiting.
private final class Typist {
    let buffer: Buffer
    var now = 0.0
    var caret: Int

    init(_ text: String, caret: Int) {
        buffer = Buffer(contentsOf: Data(text.utf8))
        self.caret = caret
        buffer.clock = { [unowned self] in now }
    }

    func type(_ s: String, gap: Double = 0.1) throws {
        for unit in s.utf16 {
            now += gap
            try buffer.apply(Patch(range: caret..<caret, replacement: [unit], origin: .source))
            caret += 1
        }
    }

    func backspace(_ n: Int, gap: Double = 0.1) throws {
        for _ in 0..<n {
            now += gap
            try buffer.apply(Patch(range: (caret - 1)..<caret, replacement: [], origin: .source), selectionBefore: caret..<caret)
            caret -= 1
        }
    }
}

@Suite("Buffer")
struct BufferTests {
    private func units(_ s: String) -> [UInt16] { Array(s.utf16) }

    @Test func rejectsARangeOutOfBounds() {
        let b = Buffer(contentsOf: Data("ab".utf8))
        #expect(throws: BufferError.rangeOutOfBounds) { try b.apply(Patch(range: 1..<9, replacement: [], origin: .source)) }
    }

    @Test func rejectsSplittingASurrogatePair() {
        let b = Buffer(contentsOf: Data("🎉".utf8))
        #expect(throws: BufferError.splitsSurrogatePair) { try b.apply(Patch(range: 1..<1, replacement: units("x"), origin: .source)) }
        #expect(throws: BufferError.splitsSurrogatePair) { try b.apply(Patch(range: 0..<1, replacement: [], origin: .source)) }
    }

    @Test func rawFilesAreReadOnly() throws {
        // Invalid UTF-8 that also contains a scalar from the escape range.
        let bytes = Data([0xFF]) + Data("\u{10FF80}".utf8)
        let b = Buffer(contentsOf: bytes)
        #expect(b.isReadOnly)
        #expect(b.serialized() == bytes)
        #expect(throws: BufferError.readOnly) { try b.apply(Patch(range: 0..<0, replacement: units("x"), origin: .source)) }
    }

    @Test func invalidBytesSurviveAnEditElsewhere() throws {
        let bytes = Data([0x61, 0xFF, 0x62])
        let b = Buffer(contentsOf: bytes)
        #expect(b.format.encoding == .utf8Escaped)
        try b.apply(Patch(range: 0..<0, replacement: units("x"), origin: .source))
        #expect(b.serialized() == Data([0x78, 0x61, 0xFF, 0x62]))
    }

    @Test func aBOMStaysOutOfTheOffsets() throws {
        let b = Buffer(contentsOf: Data([0xEF, 0xBB, 0xBF, 0x61]))
        #expect(b.units == units("a"))
        try b.apply(Patch(range: 0..<0, replacement: units("x"), origin: .source))
        #expect(b.serialized() == Data([0xEF, 0xBB, 0xBF, 0x78, 0x61]))
    }

    @Test func utf16EditsStayUTF16() throws {
        let b = Buffer(contentsOf: Data([0xFE, 0xFF, 0x00, 0x61]))
        #expect(b.format == FileFormat(encoding: .utf16BE, hasBOM: true))
        try b.apply(Patch(range: 1..<1, replacement: units("b"), origin: .source))
        #expect(b.serialized() == Data([0xFE, 0xFF, 0x00, 0x61, 0x00, 0x62]))
    }

    @Test func dirtyComparesExactly() throws {
        // Canonically equivalent to the original, so `==` on String would say clean.
        let b = Buffer(contentsOf: Data("\u{E9}".utf8))
        try b.apply(Patch(range: 0..<1, replacement: units("e\u{301}"), origin: .source))
        #expect(b.isDirty)
    }

    @Test func markSavedClearsDirty() throws {
        let b = Buffer(contentsOf: Data("a".utf8))
        try b.apply(Patch(range: 1..<1, replacement: units("b"), origin: .source))
        let data = b.serialized()
        b.markSaved(data)
        #expect(!b.isDirty)
        b.undo()
        #expect(b.isDirty)
    }

    @Test(arguments: [("a\nb", 2, "\n"), ("a\r\nb", 3, "\r\n"), ("a\rb", 2, "\r"), ("a\r\nb\nc", 6, "\n"), ("ab\r\n", 1, "\r\n"), ("ab", 1, "\n")])
    func lineEndingFollowsTheNearest(text: String, at: Int, want: String) {
        #expect(Buffer(contentsOf: Data(text.utf8)).lineEnding(at: at) == units(want))
    }

    @Test func observersSeeEveryChange() throws {
        let b = Buffer(contentsOf: Data("a".utf8))
        var seen: [Patch] = []
        let token = b.addObserver { seen.append($0) }
        try b.apply(Patch(range: 1..<1, replacement: units("b"), origin: .source))
        b.undo()
        #expect(seen.map(\.origin) == [.source, .command])
        b.removeObserver(token)
        b.redo()
        #expect(seen.count == 2)
    }

    @Test func reloadDropsHistory() throws {
        let b = Buffer(contentsOf: Data("a".utf8))
        try b.apply(Patch(range: 1..<1, replacement: units("b"), origin: .source))
        b.reload(contentsOf: Data("new".utf8))
        #expect(b.text == "new")
        #expect(!b.isDirty)
        #expect(!b.canUndo)
    }

    @Test func typingGroupsByWord() throws {
        let t = Typist("x ", caret: 2)
        try t.type("one two three")
        t.buffer.undo()
        #expect(t.buffer.text == "x one two ")
        t.buffer.undo()
        #expect(t.buffer.text == "x one ")
        t.buffer.undo()
        #expect(t.buffer.text == "x ")
        #expect(!t.buffer.canUndo)
    }

    @Test func aPauseStartsANewStep() throws {
        let t = Typist("x", caret: 1)
        try t.type("ab")
        try t.type("cd", gap: 2)
        t.buffer.undo()
        #expect(t.buffer.text == "xabc")
        t.buffer.undo()
        #expect(t.buffer.text == "xab")
        t.buffer.undo()
        #expect(t.buffer.text == "x")
    }

    @Test func backspaceRunsGroup() throws {
        let t = Typist("hello", caret: 5)
        try t.backspace(3)
        #expect(t.buffer.text == "he")
        let result = t.buffer.undo()
        #expect(t.buffer.text == "hello")
        #expect(result?.selection == 5..<5)
    }

    @Test func movingTheCaretStartsANewStep() throws {
        let t = Typist("abcd", caret: 1)
        try t.type("x")
        t.caret = 4
        try t.type("y")
        t.buffer.undo()
        #expect(t.buffer.text == "axbcd")
    }

    @Test func aNewEditClearsRedo() throws {
        let b = Buffer(contentsOf: Data("ab".utf8))
        try b.apply(Patch(range: 1..<1, replacement: units("x"), origin: .source))
        b.undo()
        #expect(b.canRedo)
        try b.apply(Patch(range: 1..<1, replacement: units("y"), origin: .source))
        #expect(!b.canRedo)
    }

    @Test func aSelectionReplacementRestoresTheSelection() throws {
        let b = Buffer(contentsOf: Data("abcd".utf8))
        try b.apply(Patch(range: 1..<3, replacement: units("x"), origin: .source), selectionBefore: 1..<3)
        #expect(b.undo()?.selection == 1..<3)
    }

    @Test func patchMinimalNeverSplitsAPair() {
        let old = units("a🎉b"), new = units("a🎊b")
        let p = Patch.minimal(from: old, to: new, origin: .source)
        #expect(p.range == 1..<3)
        #expect(p.replacement == units("🎊"))
    }

    @Test func transformCarriesOffsets() {
        let p = Patch(range: 2..<4, replacement: units("xyz"), origin: .source)
        #expect(p.transform(1) == 1)
        #expect(p.transform(2) == 2)
        #expect(p.transform(3) == 5)
        #expect(p.transform(4) == 5)
        #expect(p.transform(9) == 10)
    }
}
