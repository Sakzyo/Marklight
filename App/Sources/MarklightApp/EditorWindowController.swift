import AppKit
import MarklightCore

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editor: SourceEditor

    init(document: MarkdownDocument) {
        editor = SourceEditor(buffer: document.buffer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        window.minSize = NSSize(width: 320, height: 240)
        window.center()
        window.setFrameAutosaveName("MarklightEditor")
        window.initialFirstResponder = editor.textView
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    func windowDidBecomeKey(_ notification: Notification) {
        (document as? MarkdownDocument)?.checkForExternalChange()
    }
}
