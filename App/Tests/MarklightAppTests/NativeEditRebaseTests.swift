import AppKit
import MarklightCore
import Testing
@testable import MarklightApp

@MainActor @Suite("Edits crossing an outstanding verification or source composition")
struct NativeEditRebaseTests {
    @Test("Concurrent source changes cannot be overwritten by the preview's earlier selection")
    func renderedSelection() throws {
        // The source change happens after WebKit sent its selection and before
        // the verified result can commit, so the host has to transform intent.
        let cases: [(Range<Int>, String, String?)] = [
            (2..<2, "X", nil), (1..<2, "X", nil), (2..<3, "", nil),
            (0..<2, "X", nil), (2..<4, "X", nil),
            (3..<3, "X", "aZXd"), (1..<1, "X", "aXZd"),
            (0..<1, "XX", "XXZd"), (3..<4, "X", "aZX")
        ]
        for (range, replacement, expected) in cases {
            let buffer = Buffer(contentsOf: Data("abcd".utf8)), updater = PreviewUpdater(buffer: buffer)
            let version = buffer.version
            try buffer.apply(Patch(range: range, replacement: Array(replacement.utf16), origin: .source))
            let sourceResult = buffer.units
            let carried = updater.current(1..<3, at: version, inputType: "insertText")
            if let expected {
                let selection = try #require(carried)
                let edit = try #require(BlockSerializer.edit(IncrementalDocument(units: buffer.units),
                    inputType: "insertText", data: "Z", selection: selection, target: nil, pending: nil))
                try buffer.apply(edit.patch)
                #expect(buffer.text == expected, "source change at \(range)")
            } else {
                #expect(carried == nil, "source change at \(range)")
                #expect(buffer.units == sourceResult)
            }
        }
    }

    @Test("A stale collapsed delete cannot consume a concurrent keystroke at its caret")
    func collapsedDelete() throws {
        for kind in ["deleteContentBackward", "deleteContentForward"] {
            let buffer = Buffer(contentsOf: Data("ab".utf8)), updater = PreviewUpdater(buffer: buffer)
            let version = buffer.version
            try buffer.apply(Patch(range: 1..<1, replacement: [88], origin: .source))
            #expect(updater.current(1..<1, at: version, inputType: kind) == nil)
            #expect(updater.current(1..<1, at: version) == 2..<2, "a selection notification may still follow its text")
            #expect(buffer.text == "aXb")
        }
    }

    @Test("A stale collapsed delete cannot take new text from inside the original grapheme")
    func changedGrapheme() async throws {
        for (kind, position) in [("deleteContentBackward", 2), ("deleteContentForward", 0)] {
            let buffer = Buffer(contentsOf: Data("a\u{301}b".utf8)), updater = PreviewUpdater(buffer: buffer)
            let version = buffer.version
            try buffer.apply(Patch(range: 1..<1, replacement: [88], origin: .source))
            let selection = try #require(updater.current(position..<position, at: version, inputType: kind))
            let edit = await withCheckedContinuation { reply in
                updater.verify(inputType: kind, data: nil, selection: selection, target: nil, since: version) { _, edit in
                    reply.resume(returning: edit)
                }
            }
            #expect(edit == nil)
            #expect(buffer.text == "aX\u{301}b")
        }
    }

    @Test("A source composition preserves rendered edits inside or at either end of its original marked range")
    func sourceComposition() throws {
        _ = NSApplication.shared
        for (index, expected) in [(1, "aXZd"), (2, "abXcd"), (3, "aZXd")] {
            let buffer = Buffer(contentsOf: Data("abcd".utf8)), editor = SourceEditor(buffer: buffer)
            let view = editor.textView, missing = NSRange(location: NSNotFound, length: 0)
            view.setSelectedRange(NSRange(location: 1, length: 2))
            view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: missing)
            try buffer.apply(Patch(range: index..<index, replacement: [88], origin: .rendered))
            view.insertText("Z", replacementRange: missing)
            #expect(buffer.text == expected, "concurrent insertion at \(index)")
            #expect(view.string == expected)
        }
    }
}
