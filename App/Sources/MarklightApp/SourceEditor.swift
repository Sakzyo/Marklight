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
    /// A composition is in the text view but not the buffer until it's committed.
    private(set) var isComposing = false
    private var observer: UUID?
    /// Undo or redo moved the caret, to show what changed.
    var historyMoved: ((Range<Int>) -> Void)?

    init(buffer: Buffer) {
        self.buffer = buffer
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
            if patch.origin != .source { apply(patch) }
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
        applyingToStorage = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(patch.range), with: String(decoding: patch.replacement, as: UTF16.self))
        storage.endEditing()
        applyingToStorage = false
        textView.isEditable = !buffer.isReadOnly
    }

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), !applyingToStorage, !isComposing else { return }
        let old = range.location..<(range.location + range.length - delta)
        let new = Array((storage.string as NSString).substring(with: range).utf16)
        let selected = textView.selectedRange()
        do {
            try buffer.apply(Patch(range: old, replacement: new, origin: .source),
                             selectionBefore: selected.location..<(selected.location + selected.length))
        } catch {
            // The two copies disagree, and the buffer is the truth. Not from the
            // storage's own delegate call, which can't take another edit.
            DispatchQueue.main.async { [weak self] in self?.syncStorage() }
        }
    }

    // MARK: - Composition

    func compositionWillChange() {
        isComposing = true
    }

    /// Marked text never reaches the buffer. Whatever the composition left behind
    /// goes in as one patch.
    func compositionEnded() {
        guard isComposing, let storage = textView.textStorage else { return }
        isComposing = false
        let units = Array(storage.string.utf16)
        guard units != buffer.units else { return }
        buffer.sealUndoStep()
        let patch = Patch.minimal(from: buffer.units, to: units, origin: .source)
        try? buffer.apply(patch)
        buffer.sealUndoStep()
    }

    // MARK: - Undo

    func undo() { moveHistory(buffer.undo()) }

    func redo() { moveHistory(buffer.redo()) }

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
        editor?.compositionWillChange()
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
