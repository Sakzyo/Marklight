import AppKit
import MarklightCore

/// Which panes a window shows. The choice is remembered for the whole app.
enum PaneLayout: String {
    case source, preview, split

    static let defaultsKey = "previewLayout"

    static var remembered: PaneLayout {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(PaneLayout.init) ?? .split }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let editor: SourceEditor
    private let buffer: Buffer
    private let split = NSSplitView()
    private let previewHolder = NSView()
    /// Made the first time it's shown, since a web view isn't cheap.
    private(set) var preview: PreviewPane?
    private(set) var layout: PaneLayout
    private var dividerShare: CGFloat = 0.5
    private let defences: PreviewDefences

    /// True while the source pane follows the preview, so it doesn't echo back.
    private var followingPreview = false
    private var pendingReveal: DispatchWorkItem?
    private var selectionObserver: NSObjectProtocol?
    /// How long the source caret rests before the preview follows it.
    static let revealDelay = 0.05

    init(document: MarkdownDocument, layout: PaneLayout = .remembered, defences: PreviewDefences = PreviewDefences()) {
        editor = SourceEditor(buffer: document.buffer)
        buffer = document.buffer
        self.layout = layout
        self.defences = defences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(editor.scrollView)
        split.addArrangedSubview(previewHolder)
        window.contentView = split
        window.minSize = NSSize(width: 320, height: 240)
        window.center()
        window.setFrameAutosaveName("MarklightEditor")
        window.initialFirstResponder = editor.textView
        super.init(window: window)
        window.delegate = self
        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor.textView,
                                                                   queue: nil) { [weak self] _ in self?.sourceSelectionChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    deinit {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
    }

    override func showWindow(_ sender: Any?) {
        applyLayout()
        super.showWindow(sender)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        (document as? MarkdownDocument)?.checkForExternalChange()
    }

    // MARK: - Layout

    /// Switches this window, and every window opened from now on.
    func setLayout(_ new: PaneLayout) {
        rememberDivider()
        layout = new
        PaneLayout.remembered = new
        applyLayout()
    }

    private func applyLayout() {
        let showsSource = layout != .preview, showsPreview = layout != .source
        if showsPreview { makePreviewIfNeeded() }
        editor.scrollView.isHidden = !showsSource
        previewHolder.isHidden = !showsPreview
        split.adjustSubviews()
        if layout == .split {
            split.setPosition((split.bounds.width * dividerShare).rounded(), ofDividerAt: 0)
        }
        preview?.setVisible(showsPreview)

        let focus: NSView? = showsSource ? editor.textView : preview?.webView
        window?.initialFirstResponder = focus
        if window?.isVisible == true, let focus { window?.makeFirstResponder(focus) }
    }

    private func rememberDivider() {
        guard layout == .split, split.bounds.width > 0 else { return }
        let share = editor.scrollView.frame.width / split.bounds.width
        if share > 0.05, share < 0.95 { dividerShare = share }
    }

    private func makePreviewIfNeeded() {
        guard preview == nil else { return }
        let pane = PreviewPane(buffer: buffer, documentURL: (document as? MarkdownDocument)?.fileURL, defences: defences)
        pane.selectionChanged = { [weak self] range in self?.followPreview(range) }
        pane.webView.undoAction = { [weak self] in self?.editor.undo() }
        pane.webView.redoAction = { [weak self] in self?.editor.redo() }
        pane.webView.canUndo = { [weak self] in self?.buffer.canUndo ?? false }
        pane.webView.canRedo = { [weak self] in self?.buffer.canRedo ?? false }
        pane.view.translatesAutoresizingMaskIntoConstraints = true
        pane.view.autoresizingMask = [.width, .height]
        pane.view.frame = previewHolder.bounds
        previewHolder.addSubview(pane.view)
        preview = pane
    }

    func documentMoved(to url: URL?) {
        preview?.documentMoved(to: url)
    }

    @objc func showSourceLayout(_ sender: Any?) { setLayout(.source) }

    @objc func showPreviewLayout(_ sender: Any?) { setLayout(.preview) }

    @objc func showSplitLayout(_ sender: Any?) { setLayout(.split) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showSourceLayout(_:)): item.state = layout == .source ? .on : .off
        case #selector(showPreviewLayout(_:)): item.state = layout == .preview ? .on : .off
        case #selector(showSplitLayout(_:)): item.state = layout == .split ? .on : .off
        default: break
        }
        return true
    }

    // MARK: - Selection sync

    private func sourceSelectionChanged() {
        guard !followingPreview, layout == .split else { return }
        pendingReveal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            preview?.reveal(editor.textView.selectedRange().location)
        }
        pendingReveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EditorWindowController.revealDelay, execute: work)
    }

    private func followPreview(_ range: Range<Int>) {
        let view = editor.textView
        guard !editor.isComposing, let length = view.textStorage?.length, range.upperBound <= length else { return }
        followingPreview = true
        defer { followingPreview = false }
        view.setSelectedRange(NSRange(range))
        view.scrollRangeToVisible(NSRange(range))
    }
}
