import AppKit
import MarklightCore

/// The source pane: an NSTextView showing the buffer. Its text storage is a copy,
/// and every edit in it becomes a patch on the buffer.
final class SourceEditor: NSObject, NSTextStorageDelegate {
    let buffer: Buffer
    let textView: SourceTextView
    let scrollView: NSScrollView
    private let highlighter: SourceHighlighter
    /// True while Swift writes to the text storage, so a change doesn't echo back.
    private var applyingToStorage = false
    private var sendingSourcePatch = false
    private var compositionBase: (units: [UInt16], selection: Range<Int>?)?
    private var changesDuringComposition: [Patch] = []
    /// A composition is in the text view but not the buffer until it's committed.
    private(set) var isComposing = false
    private var observer: UUID?
    /// Undo or redo moved the caret, to show what changed.
    var historyMoved: ((Range<Int>) -> Void)?
    var changeHistory: (Bool) -> (patch: Patch, selection: Range<Int>)?

    init(buffer: Buffer) {
        self.buffer = buffer
        changeHistory = { redo in redo ? buffer.redo() : buffer.undo() }
        textView = SourceTextView(usingTextLayoutManager: true)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 820))
        highlighter = SourceHighlighter(buffer: buffer, textView: textView)
        super.init()
        configure()
        textView.editor = self
        textView.textStorage?.delegate = self
        syncStorage()
        textView.setSelectedRange(NSRange(location: 0, length: 0)) // setting the text leaves the caret at the end
        observer = buffer.addObserver { [weak self] patch in
            guard let self else { return }
            if !sendingSourcePatch {
                if isComposing { changesDuringComposition.append(patch) }
                else { apply(patch) }
            }
            highlighter.scheduleUpdate()
        }
        highlighter.update()
    }

    private func configure() {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false // the buffer owns undo
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.typingAttributes = SourceTheme.base
        textView.isEditable = !buffer.isReadOnly
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.frame = scrollView.bounds
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
    }

    private func syncStorage() {
        applyingToStorage = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: buffer.text, attributes: SourceTheme.base))
        applyingToStorage = false
    }

    /// Writes a change that didn't start here, such as undo or a reload from disk.
    private func apply(_ patch: Patch) {
        guard let storage = textView.textStorage else { return }
        let beforeLength = buffer.units.count - patch.replacement.count + patch.range.count
        guard storage.length == beforeLength, patch.range.upperBound <= storage.length else {
            syncStorage()
            textView.isEditable = !buffer.isReadOnly
            return
        }
        let selected = textView.selectedRange(), clip = scrollView.contentView
        let origin = clip.bounds.origin
        var anchor: (offset: Int, screenY: CGFloat)?
        if patch.origin == .rendered && origin.y > 0 && !scrollView.isHidden {
            let point = textView.convert(NSPoint(x: clip.bounds.minX + textView.textContainerInset.width + 2,
                                                 y: clip.bounds.minY + 2), from: clip)
            let index = textView.characterIndexForInsertion(at: point)
            if patch.range.upperBound <= index && index <= storage.length {
                anchor = (patch.transform(index), textView.firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil).minY)
            }
        }
        applyingToStorage = true
        storage.replaceCharacters(in: NSRange(patch.range), with: String(decoding: patch.replacement, as: UTF16.self))
        if selected.location != NSNotFound {
            let from = patch.transform(selected.location), to = patch.transform(NSMaxRange(selected))
            let mapped = NSRange(location: from, length: to - from)
            if textView.selectedRange() != mapped { textView.setSelectedRange(mapped) }
        }
        if let anchor {
            let rect = textView.firstRect(forCharacterRange: NSRange(location: anchor.offset, length: 0), actualRange: nil)
            clip.scroll(to: NSPoint(x: origin.x, y: clip.bounds.origin.y + anchor.screenY - rect.minY))
        } else if origin != clip.bounds.origin {
            clip.scroll(to: origin)
        }
        applyingToStorage = false
        textView.isEditable = !buffer.isReadOnly
    }

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), !applyingToStorage, !isComposing else { return }
        let old = range.location..<(range.location + range.length - delta)
        let new = Array((storage.string as NSString).substring(with: range).utf16)
        let selected = textView.selectedRange()
        sendingSourcePatch = true
        defer { sendingSourcePatch = false }
        do {
            guard old.upperBound <= buffer.units.count else { throw BufferError.rangeOutOfBounds }
            let selection = selected.location..<(selected.location + selected.length)
            let patch = storagePatch(in: buffer.units, range: old, replacement: new, selection: selection)
            try buffer.apply(patch, selectionBefore: selection)
        } catch {
            // The two copies disagree, and the buffer is the truth. Not from the
            // storage's own delegate call, which can't take another edit.
            DispatchQueue.main.async { [weak self] in self?.syncStorage() }
        }
    }

    /// TextKit sometimes reports an entire attributed line for one key. Prefer
    /// the actual selection if the bytes outside it are known to be unchanged.
    private func storagePatch(in units: [UInt16], range: Range<Int>, replacement: [UInt16], selection: Range<Int>?) -> Patch {
        if range.isEmpty || range == selection { return Patch(range: range, replacement: replacement, origin: .source) }
        let original = units[range]
        if let selection {
            let start = selection.lowerBound - range.lowerBound, tail = range.upperBound - selection.upperBound
            if start >= 0, tail >= 0, start + tail <= replacement.count,
               original.prefix(start).elementsEqual(replacement.prefix(start)),
               original.suffix(tail).elementsEqual(replacement.suffix(tail)) {
                return Patch(range: selection, replacement: Array(replacement[start..<(replacement.count - tail)]), origin: .source)
            }
        }
        let part = Patch.minimal(from: Array(original), to: replacement, origin: .source)
        return Patch(range: (range.lowerBound + part.range.lowerBound)..<(range.lowerBound + part.range.upperBound),
                     replacement: part.replacement, origin: .source)
    }

    // MARK: - Composition

    func compositionWillChange(replacing replacement: NSRange) {
        guard !isComposing else { return }
        let selection = replacement.location == NSNotFound ? textView.selectedRange() : replacement
        compositionBase = (buffer.units, Range(selection))
        isComposing = true
    }

    /// Marked text never reaches the buffer. Verify any change from the other
    /// pane against the original marked selection before committing anything.
    func compositionEnded() {
        guard isComposing, let base = compositionBase, let storage = textView.textStorage else { return }
        isComposing = false
        compositionBase = nil
        let remote = changesDuringComposition
        changesDuringComposition.removeAll()
        let units = Array(storage.string.utf16)
        if !remote.isEmpty { syncStorage() }
        guard units != base.units else { return }
        var patch = storagePatch(in: base.units, range: 0..<base.units.count, replacement: units, selection: base.selection)
        var selection = base.selection ?? patch.range
        for change in remote {
            guard let nextSelection = rebaseEdit(selection, over: change),
                  let nextRange = rebaseEdit(patch.range, over: change) else { NSSound.beep(); return }
            selection = nextSelection
            patch = Patch(range: nextRange, replacement: patch.replacement, origin: .source)
        }
        buffer.sealUndoStep()
        sendingSourcePatch = remote.isEmpty
        defer { sendingSourcePatch = false }
        let end = patch.range.lowerBound + patch.replacement.count
        let part = Patch.minimal(from: Array(buffer.units[patch.range]), to: patch.replacement, origin: .source)
        let start = patch.range.lowerBound
        patch = Patch(range: (start + part.range.lowerBound)..<(start + part.range.upperBound),
                      replacement: part.replacement, origin: .source)
        do {
            try buffer.apply(patch, selectionBefore: selection)
            if !remote.isEmpty { textView.setSelectedRange(NSRange(location: end, length: 0)) }
        } catch {
            syncStorage()
            NSSound.beep()
        }
        buffer.sealUndoStep()
    }

    // MARK: - Undo

    func undo() { moveHistory(changeHistory(false)) }

    func redo() { moveHistory(changeHistory(true)) }

    private func moveHistory(_ result: (patch: Patch, selection: Range<Int>)?) {
        guard let result else { return }
        let range = NSRange(result.selection)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        historyMoved?(result.selection)
    }
}

/// The text view's own behavior, where Markdown needs something else.
final class SourceTextView: NSTextView {
    weak var editor: SourceEditor?

    @objc func undo(_ sender: Any?) { editor?.undo() }

    @objc func redo(_ sender: Any?) { editor?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return editor?.buffer.canUndo ?? false
        case #selector(redo(_:)): return editor?.buffer.canRedo ?? false
        default: return super.validateUserInterfaceItem(item)
        }
    }

    /// New lines match the ones around them, so a CRLF file stays CRLF.
    private var lineEnding: String {
        let offset = selectedRange().location
        return String(decoding: editor?.buffer.lineEnding(at: offset) ?? [0x0A], as: UTF16.self)
    }

    override func insertNewline(_ sender: Any?) { insertText(lineEnding, replacementRange: selectedRange()) }

    override func insertLineBreak(_ sender: Any?) { insertText(lineEnding, replacementRange: selectedRange()) }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertText(lineEnding, replacementRange: selectedRange()) }

    override func paste(_ sender: Any?) {
        guard isEditable, let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteText(text)
    }

    func pasteText(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: lineEnding)
        insertText(normalized, replacementRange: selectedRange())
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        editor?.compositionWillChange(replacing: replacementRange)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        super.unmarkText()
        editor?.compositionEnded()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        editor?.compositionEnded()
    }
}
