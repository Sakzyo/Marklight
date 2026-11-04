import AppKit
import CryptoKit
import Foundation
import Testing
import MarklightCore
@testable import MarklightApp

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures")

private let fixtureNames = ((try? FileManager.default.contentsOfDirectory(atPath: fixtures.path)) ?? [])
    .filter { !$0.hasPrefix(".") }.sorted()

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

/// A temporary folder for one test.
private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("marklight-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: realpath(url.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? url.path)
}

private func file(_ text: String, _ folder: URL, name: String = "doc.md") throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
}

@MainActor private func open(_ url: URL) throws -> (doc: MarkdownDocument, view: SourceTextView, editor: SourceEditor) {
    _ = NSApplication.shared
    let doc = try MarkdownDocument(contentsOf: url, ofType: MarkdownDocument.markdownType)
    doc.makeWindowControllers()
    let controller = doc.windowControllers[0] as! EditorWindowController
    return (doc, controller.editor.textView, controller.editor)
}

@MainActor private func save(_ doc: MarkdownDocument) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        doc.save(to: doc.fileURL!, ofType: doc.fileType!, for: .saveOperation) { error in
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
}

@MainActor private func type(_ s: String, _ view: SourceTextView) {
    for ch in s { view.insertText(String(ch), replacementRange: view.selectedRange()) }
}

/// Lets main-queue work run until `condition` holds, or two seconds pass.
@MainActor private func wait(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor @Suite("Document", .serialized)
struct DocumentTests {
    @Test("Open, no-op, save is byte-identical through the real document", arguments: fixtureNames)
    func noOpSave(name: String) async throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: url)
        let before = try sha256(url)
        let (doc, view, _) = try open(url)
        #expect(view.string.utf8.elementsEqual(doc.buffer.text.utf8))
        #expect(!doc.isDocumentEdited)
        try await save(doc)
        #expect(try sha256(url) == before)
    }

    @Test("An edit and its undo, saved, are byte-identical", arguments: fixtureNames)
    func editUndoSave(name: String) async throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: url)
        let before = try sha256(url)
        let (doc, view, editor) = try open(url)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("x", view)
        #expect(doc.buffer.units.first == 0x78)
        #expect(view.string.utf8.elementsEqual(doc.buffer.text.utf8))
        #expect(doc.isDocumentEdited)
        editor.undo()
        #expect(!doc.isDocumentEdited)
        #expect(view.string.utf8.elementsEqual(doc.buffer.text.utf8))
        try await save(doc)
        #expect(try sha256(url) == before)
    }

    @Test func typingChangesOnlyTheTypedBytes() async throws {
        let url = try file("one\n\ntwo\n", try makeFolder())
        let (doc, view, _) = try open(url)
        view.setSelectedRange(NSRange(location: 3, length: 0))
        type("!", view)
        try await save(doc)
        #expect(try Data(contentsOf: url) == Data("one!\n\ntwo\n".utf8))
        #expect(!doc.isDocumentEdited)
    }

    @Test func enterFollowsTheFilesLineEndings() async throws {
        let url = try file("a\r\nb\r\n", try makeFolder())
        let (doc, view, _) = try open(url)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertNewline(nil)
        try await save(doc)
        #expect(try Data(contentsOf: url) == Data("a\r\n\r\nb\r\n".utf8))
    }

    @Test func pasteFollowsTheFilesLineEndings() throws {
        let url = try file("a\r\n", try makeFolder())
        let (doc, view, _) = try open(url)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.pasteText("x\ny\rz\r\nw")
        #expect(doc.buffer.text == "ax\r\ny\r\nz\r\nw\r\n")
    }

    @Test func encodingsSurviveAnEdit() async throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("doc.md")
        try Data([0xFE, 0xFF, 0x00, 0x61]).write(to: url)
        let (doc, view, _) = try open(url)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        type("b", view)
        try await save(doc)
        #expect(try Data(contentsOf: url) == Data([0xFE, 0xFF, 0x00, 0x61, 0x00, 0x62]))
    }

    @Test func invalidBytesSurviveAnEdit() async throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("doc.md")
        try Data([0x61, 0xFF, 0x62]).write(to: url)
        let (doc, view, _) = try open(url)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("x", view)
        try await save(doc)
        #expect(try Data(contentsOf: url) == Data([0x78, 0x61, 0xFF, 0x62]))
    }

    @Test func aFileThatCantBeDecodedIsReadOnly() async throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("doc.md")
        let bytes = Data([0xFF]) + Data("\u{10FF80}".utf8)
        try bytes.write(to: url)
        let (doc, view, _) = try open(url)
        #expect(!view.isEditable)
        try await save(doc)
        #expect(try Data(contentsOf: url) == bytes)
    }

    // MARK: - File system

    @Test func saveKeepsModeAndAttributes() async throws {
        let url = try file("a\n", try makeFolder())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let value = Array("kept".utf8)
        setxattr(url.path, "com.marklight.test", value, value.count, 0, 0)
        let (doc, view, _) = try open(url)
        type("x", view)
        try await save(doc)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
        #expect(getxattr(url.path, "com.marklight.test", nil, 0, 0, 0) == value.count)
    }

    @Test func aSymlinkOpensAsItsTargetAndSurvivesASave() async throws {
        let folder = try makeFolder()
        let real = try file("a\n", folder, name: "real.md")
        let link = folder.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real.md")
        let (doc, view, _) = try open(link)
        #expect(doc.fileURL?.path == real.path)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("x", view)
        try await save(doc)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "real.md")
        #expect(try Data(contentsOf: real) == Data("xa\n".utf8))
    }

    @Test func aHardLinkSeesTheSave() async throws {
        let folder = try makeFolder()
        let url = try file("a\n", folder)
        let other = folder.appendingPathComponent("other.md")
        try FileManager.default.linkItem(at: url, to: other)
        let (doc, view, _) = try open(url)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("x", view)
        try await save(doc)
        #expect(try Data(contentsOf: other) == Data("xa\n".utf8))
        #expect(FileWatcher.linkCount(of: url) == 2)
        type("y", view)
        try await save(doc) // no "changed by another application" error
        #expect(try Data(contentsOf: other) == Data("xya\n".utf8))
    }

    @Test func aFailedSaveLeavesTheDocumentDirty() async throws {
        let folder = try makeFolder()
        let url = try file("a\n", folder)
        let (doc, view, _) = try open(url)
        type("x", view)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        await #expect(throws: (any Error).self) { try await save(doc) }
        #expect(doc.isDocumentEdited)
        #expect(doc.buffer.isDirty)
    }

    // MARK: - External changes

    @Test func aCleanDocumentFollowsTheDisk() async throws {
        let url = try file("a\n", try makeFolder())
        let (doc, view, _) = try open(url)
        try Data("b\n".utf8).write(to: url) // in place
        #expect(await wait { doc.buffer.text == "b\n" })
        #expect(view.string == "b\n")
        #expect(!doc.isDocumentEdited)
    }

    @Test func aFileReplacedLikeGitCheckoutIsNoticed() async throws {
        let url = try file("a\n", try makeFolder())
        let (doc, view, _) = try open(url)
        try Data("b\n".utf8).write(to: url, options: .atomic) // a rename over the file
        #expect(await wait { doc.buffer.text == "b\n" })
        try Data("c\n".utf8).write(to: url, options: .atomic) // the watch moved to the new file
        #expect(await wait { doc.buffer.text == "c\n" })
        #expect(view.string == "c\n")
    }

    @Test func dirtyAndDeclinedKeepsTheEdits() async throws {
        let url = try file("a\n", try makeFolder())
        let (doc, view, _) = try open(url)
        var prompts = 0
        doc.externalChangePrompt = { decide in
            prompts += 1
            decide(false)
        }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("x", view)
        try Data("b\n".utf8).write(to: url, options: .atomic)
        #expect(await wait { prompts == 1 })
        #expect(doc.buffer.text == "xa\n")
        doc.checkForExternalChange()
        #expect(prompts == 1) // not asked twice about the same bytes
        try await save(doc)
        #expect(try Data(contentsOf: url) == Data("xa\n".utf8))
    }

    @Test func dirtyAndReloadTakesTheDisk() async throws {
        let url = try file("a\n", try makeFolder())
        let (doc, view, _) = try open(url)
        doc.externalChangePrompt = { $0(true) }
        type("x", view)
        try Data("b\n".utf8).write(to: url, options: .atomic)
        #expect(await wait { doc.buffer.text == "b\n" })
        #expect(view.string == "b\n")
        #expect(!doc.isDocumentEdited)
        #expect(!doc.buffer.canUndo)
    }

    @Test func ourOwnSaveIsntAnExternalChange() async throws {
        let url = try file("a\n", try makeFolder())
        let (doc, view, _) = try open(url)
        var prompts = 0
        doc.externalChangePrompt = { _ in prompts += 1 }
        type("x", view)
        try await save(doc)
        type("y", view)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(prompts == 0)
        #expect(doc.buffer.text.contains("y"))
    }

    @Test func aDeletedFileDoesntLoseTheEditor() async throws {
        let url = try file("a\n", try makeFolder())
        let (doc, view, _) = try open(url)
        try FileManager.default.removeItem(at: url)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(view.string == "a\n")
        #expect(doc.buffer.text == "a\n")
    }

    // MARK: - Undo through the view

    @Test func undoRedoThroughTheTextView() throws {
        let url = try file("ab\n", try makeFolder())
        let (doc, view, _) = try open(url)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        type("x", view)
        view.undo(nil)
        #expect(view.string == "ab\n")
        #expect(view.selectedRange().location == 1)
        #expect(!doc.isDocumentEdited)
        view.redo(nil)
        #expect(view.string == "axb\n")
        #expect(doc.isDocumentEdited)
    }

    @Test func undoMenuItemsFollowTheBuffer() throws {
        let url = try file("ab\n", try makeFolder())
        let (doc, view, _) = try open(url)
        defer { withExtendedLifetime(doc) {} }
        let undo = NSMenuItem(title: "Undo", action: #selector(SourceTextView.undo(_:)), keyEquivalent: "")
        let redo = NSMenuItem(title: "Redo", action: #selector(SourceTextView.redo(_:)), keyEquivalent: "")
        #expect(!view.validateUserInterfaceItem(undo))
        type("x", view)
        #expect(view.validateUserInterfaceItem(undo))
        view.undo(nil)
        #expect(view.validateUserInterfaceItem(redo))
    }

    @Test func revertBringsBackTheFile() throws {
        let url = try file("ab\n", try makeFolder())
        let (doc, view, _) = try open(url)
        type("x", view)
        try doc.revert(toContentsOf: url, ofType: doc.fileType!)
        #expect(view.string == "ab\n")
        #expect(!doc.isDocumentEdited)
    }

    @Test func anUntitledDocumentSavesAsUTF8() async throws {
        _ = NSApplication.shared
        let doc = MarkdownDocument()
        doc.makeWindowControllers()
        let view = (doc.windowControllers[0] as! EditorWindowController).editor.textView
        type("# New", view)
        view.insertNewline(nil)
        let url = try makeFolder().appendingPathComponent("new.md")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            doc.save(to: url, ofType: MarkdownDocument.markdownType, for: .saveAsOperation) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        #expect(try Data(contentsOf: url) == Data("# New\n".utf8))
        #expect(doc.fileURL == url)
        #expect(!doc.isDocumentEdited)
        type("!", view)
        try Data("# Other\n".utf8).write(to: url, options: .atomic)
        var prompted = false
        doc.externalChangePrompt = { _ in prompted = true }
        #expect(await wait { prompted }) // the watch followed the new name
    }

    @Test func findBarOpensFromTheMenuAction() throws {
        let url = try file("needle in a haystack\n", try makeFolder())
        let (doc, view, editor) = try open(url)
        defer { withExtendedLifetime(doc) {} }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(item)
        #expect(editor.scrollView.isFindBarVisible)
        #expect(view.usesFindBar)
    }

    @Test func theMenuReachesItsActions() {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        let titles = menu.items.compactMap { $0.submenu?.title }
        #expect(titles == ["Marklight", "File", "Edit", "Window"])
        let edit = menu.items[2].submenu!
        #expect(edit.item(withTitle: "Undo")?.action == #selector(SourceTextView.undo(_:)))
        #expect(edit.item(withTitle: "Find")?.submenu?.items.count == 5)
    }

    /// Set MARKLIGHT_LARGE_FILE to a Markdown path to print timings.
    @Test func largeFileTimings() async throws {
        guard let path = ProcessInfo.processInfo.environment["MARKLIGHT_LARGE_FILE"] else { return }
        let source = URL(fileURLWithPath: path)
        let url = try makeFolder().appendingPathComponent("large.md")
        try FileManager.default.copyItem(at: source, to: url)
        let clock = ContinuousClock()
        var opened: (doc: MarkdownDocument, view: SourceTextView, editor: SourceEditor)!
        let openTime = clock.measure { opened = try! open(url) }
        let (doc, view, _) = opened!
        defer { withExtendedLifetime(doc) {} }
        var highlighted = Duration.zero
        let t0 = clock.now
        let done = await wait { (view.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false }
        highlighted = clock.now - t0
        view.setSelectedRange(NSRange(location: view.string.utf16.count / 2, length: 0))
        var total = Duration.zero
        for _ in 0..<50 {
            total += clock.measure { view.insertText("x", replacementRange: view.selectedRange()) }
        }
        let saveTime = clock.now
        try await save(doc)
        print("LARGE \(try Data(contentsOf: source).count / 1024) KB: open \(openTime), first highlight \(highlighted) (\(done)), keystroke \(total / 50), save \(clock.now - saveTime)")
    }

    // MARK: - Composition in the source pane

    @Test func markedTextStaysOutOfTheBuffer() throws {
        let url = try file("ab\n", try makeFolder())
        let (doc, view, _) = try open(url)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let none = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        #expect(doc.buffer.text == "ab\n")
        #expect(view.string == "anib\n")
        view.insertText("你", replacementRange: none)
        #expect(doc.buffer.text == "a你b\n")
        #expect(view.string == "a你b\n")
        #expect(doc.buffer.undo() != nil)
        #expect(doc.buffer.text == "ab\n")
        #expect(view.string == "ab\n")
    }

    @Test func aCancelledCompositionChangesNothing() throws {
        let url = try file("ab\n", try makeFolder())
        let (doc, view, _) = try open(url)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let none = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)
        view.unmarkText()
        #expect(doc.buffer.text == "ab\n")
        #expect(view.string == "ab\n")
        #expect(!doc.isDocumentEdited)
    }

    // MARK: - Highlighting

    private func font(_ view: NSTextView, at i: Int) -> NSFontDescriptor.SymbolicTraits {
        (view.textStorage?.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits ?? []
    }

    private func color(_ view: NSTextView, at i: Int) -> NSColor? {
        view.textStorage?.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
    }

    @Test func highlightingFollowsTheStructure() async throws {
        let url = try file("# Title\n\nplain **bold** *it* `code`\n", try makeFolder())
        let (doc, view, _) = try open(url)
        defer { withExtendedLifetime(doc) {} }
        #expect(await wait { font(view, at: 17).contains(.bold) })
        #expect(color(view, at: 2) == SourceTheme.attributes(.heading(1))[.foregroundColor] as? NSColor)
        #expect(color(view, at: 9) == NSColor.labelColor)
        #expect(font(view, at: 25).contains(.italic))
        #expect(color(view, at: 30) == SourceTheme.attributes(.code)[.foregroundColor] as? NSColor)
    }

    @Test func highlightingFollowsEdits() async throws {
        let url = try file("plain\n\nmore\n", try makeFolder())
        let (doc, view, _) = try open(url)
        defer { withExtendedLifetime(doc) {} }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("**", view)
        view.setSelectedRange(NSRange(location: 7, length: 0))
        type("**", view)
        #expect(await wait { font(view, at: 3).contains(.bold) })
        view.setSelectedRange(NSRange(location: 7, length: 2))
        view.insertText("", replacementRange: view.selectedRange())
        #expect(await wait { !font(view, at: 3).contains(.bold) })
    }

    @Test func editsAfterASpanDontDisturbIt() async throws {
        let url = try file("**bold** tail\n\nmore\n", try makeFolder())
        let (doc, view, _) = try open(url)
        #expect(await wait { font(view, at: 3).contains(.bold) })
        view.setSelectedRange(NSRange(location: 19, length: 0))
        type("x", view)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(font(view, at: 3).contains(.bold))
        #expect(!font(view, at: 10).contains(.bold))
        #expect(doc.buffer.text.hasSuffix("morex\n"))
    }
}
