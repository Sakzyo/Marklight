import AppKit
import MarklightCore
import WebKit

/// The security layers that can be turned off. Only the control run in the tests
/// ever does, to show that the tests can see an attack get through.
struct PreviewDefences {
    var contentSecurityPolicy = true
    var pageJavaScriptOff = true
}

/// The rendered pane: a web view showing the buffer. Rendered input is verified by Swift.
///
/// Rendered content is untrusted (`docs/plan.md` 2.6). The page runs no script,
/// Marklight's JS lives in an isolated content world, and the page can't navigate.
final class PreviewPane: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "marklight")
    private static let messageHandler = "marklight"

    let view: NSStackView
    let webView: PreviewWebView
    let updater: PreviewUpdater
    private let buffer: Buffer
    let scheme: PreviewSchemeHandler
    let bar = RemoteImagesBar()
    private let defences: PreviewDefences

    private var location: PreviewLocation
    /// The one navigation the preview allows: its own page, once per load.
    private var pageLoadPending = false
    private(set) var remoteImagesAllowed = false
    private var scrollToRestore: Double?
    private var pendingReveal: Int?
    private var inFlight = false
    private var waitingForVersion: Int?
    private var generation = 0
    var beep: () -> Void = { NSSound.beep() }
    private(set) var rejectedMessages: [String] = []

    /// The user clicked or selected in the preview. The range is in the current text.
    var selectionChanged: ((Range<Int>) -> Void)?
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var openMarkdown: (URL) -> Void = { url in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    init(buffer: Buffer, documentURL: URL?, defences: PreviewDefences = PreviewDefences()) {
        self.buffer = buffer
        self.defences = defences
        location = PreviewLocation(documentURL: documentURL)
        updater = PreviewUpdater(buffer: buffer)
        scheme = PreviewSchemeHandler(location: location, page: { WebAssets.text("preview.html") })
        scheme.csp = defences.contentSecurityPolicy ? PreviewScheme.csp(remoteImages: false) : nil

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(scheme, forURLScheme: PreviewScheme.name)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = !defences.pageJavaScriptOff
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let script = WebAssets.text("purify.min.js") + "\n" + WebAssets.text("preview.js")
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true, in: PreviewPane.world))
        webView = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)

        view = NSStackView(views: [bar, webView])
        view.orientation = .vertical
        view.spacing = 0
        view.alignment = .leading
        view.setHuggingPriority(.defaultLow, for: .horizontal)
        view.setHuggingPriority(.defaultLow, for: .vertical)
        super.init()

        configuration.userContentController.add(WeakMessageHandler(self), contentWorld: PreviewPane.world, name: PreviewPane.messageHandler)
        bar.isHidden = true
        bar.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        webView.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        bar.load = { [weak self] in self?.allowRemoteImages() }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        updater.present = { [weak self] update, done in
            guard let self else { return done(false) }
            present(update, done: done)
        }
        updater.caughtUp = { [weak self] in self?.flushReveal() }
        updater.presented = { [weak self] version in
            guard let self, let waiting = waitingForVersion, version >= waiting else { return }
            finishInput()
        }
        webView.undoAction = { [weak self] in self?.menuHistory(redo: false) }
        webView.redoAction = { [weak self] in self?.menuHistory(redo: true) }
        webView.canUndo = { [weak self] in self.map { $0.inFlight || $0.buffer.canUndo } ?? false }
        webView.canRedo = { [weak self] in self?.buffer.canRedo ?? false }
        loadPage()
    }

    /// Hiding the pane stops the work it would do. Showing it catches up.
    func setVisible(_ visible: Bool) {
        updater.setPaused(!visible)
    }

    /// The document was saved somewhere else, so its root and page URL change.
    func documentMoved(to url: URL?) {
        let new = PreviewLocation(documentURL: url)
        guard new != location else { return }
        location = new
        scheme.location = new
        reloadKeepingScroll()
    }

    // MARK: - Page

    private func loadPage() {
        generation += 1
        inFlight = false
        waitingForVersion = nil
        pageLoadPending = true
        updater.pageWillLoad()
        webView.load(URLRequest(url: location.pageURL))
    }

    private func reloadKeepingScroll() {
        webView.callAsyncJavaScript("return scrollY", arguments: [:], in: nil, in: PreviewPane.world) { [weak self] result in
            guard let self else { return }
            if case .success(let y) = result { scrollToRestore = y as? Double }
            loadPage()
        }
    }

    func allowRemoteImages() {
        guard !remoteImagesAllowed else { return }
        remoteImagesAllowed = true
        bar.isHidden = true
        if defences.contentSecurityPolicy { scheme.csp = PreviewScheme.csp(remoteImages: true) }
        reloadKeepingScroll()
    }

    private func present(_ update: PreviewUpdate, done: @escaping (Bool) -> Void) {
        bar.isHidden = !update.hasRemoteImages || remoteImagesAllowed
        func block(_ b: RenderedBlock) -> [String: Any] { ["html": b.html, "base": b.base] }
        let code: String
        let arguments: [String: Any]
        switch update.content {
        case .load(let blocks):
            code = """
            document.getElementById('doc').contentEditable = editable ? 'true' : 'false';
            marklight.load(list, v, start, end);
            """
            arguments = ["list": blocks.map(block), "v": update.version, "editable": !buffer.isReadOnly,
                         "start": update.caret?.lowerBound as Any? ?? NSNull(), "end": update.caret?.upperBound as Any? ?? NSNull()]
        case .patch(let patch):
            code = """
            const doc = document.getElementById('doc');
            if (doc.isContentEditable !== editable) doc.contentEditable = editable ? 'true' : 'false';
            marklight.patch(m);
            """
            arguments = ["editable": !buffer.isReadOnly, "m": ["v": update.version, "from": patch.from, "remove": patch.remove,
                               "list": patch.list.map(block), "delta": patch.delta,
                               "local": update.caret != nil, "edits": update.edits,
                               "caret": update.caret.map { [$0.lowerBound, $0.upperBound] } as Any? ?? NSNull()] as [String: Any]]
        }
        webView.callAsyncJavaScript(code, arguments: arguments, in: nil, in: PreviewPane.world) { [weak self] result in
            if case .failure = result { return done(false) }
            if let y = self?.scrollToRestore, case .load = update.content {
                self?.scrollToRestore = nil
                self?.webView.callAsyncJavaScript("window.scrollTo(0, y)", arguments: ["y": y], in: nil, in: PreviewPane.world)
            }
            done(true)
        }
    }

    // MARK: - Selection

    /// Scrolls to the block at `offset`, once the page has the text it refers to.
    func reveal(_ offset: Int) {
        pendingReveal = offset
        flushReveal()
    }

    private func flushReveal() {
        guard updater.isCurrent, let offset = pendingReveal else { return }
        pendingReveal = nil
        webView.callAsyncJavaScript("marklight.reveal(offset)", arguments: ["offset": offset], in: nil, in: PreviewPane.world)
    }

    // MARK: - Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return reject(message)
        }
        switch type {
        case "ready" where body.count == 1:
            updater.pageReady()
        case "selection" where body.count == 4:
            guard let v = Self.integer(body["v"]), v >= 0, v <= buffer.version,
                  let range = Self.range(body["start"], body["end"]) else { return reject(message) }
            if let current = updater.current(range, at: v) { selectionChanged?(current) }
        case "input":
            guard !inFlight, let input = Input(body) else { return reject(message) }
            inFlight = true
            apply(input)
        case "undo" where body.count == 3:
            guard !inFlight, let v = Self.integer(body["v"]), v >= 0, v <= buffer.version,
                  let redo = Self.boolean(body["redo"]) else { return reject(message) }
            inFlight = true
            guard let result = redo ? buffer.redo() : buffer.undo() else { return finishInput() }
            waitingForVersion = buffer.version
            updater.historyMoved(to: result.selection)
        default:
            reject(message)
        }
    }

    private struct Input {
        let version: Int
        let type: String
        let data: String?
        let selection: Range<Int>
        let target: Range<Int>?
        let targetVersion: Int
        let composed: Bool

        init?(_ body: [String: Any]) {
            guard body.count == 10, let v = integer(body["v"]), let kind = body["inputType"] as? String,
                  let tv = integer(body["targetV"]), let composed = boolean(body["composed"]),
                  let selected = range(body["start"], body["end"]),
                  let data = body["data"], data is NSNull || data is String,
                  let rawTarget = body["target"], let rawRange = body["range"] else { return nil }
            func pair(_ value: Any) -> Range<Int>? {
                guard let pair = value as? [Any], pair.count == 2 else { return nil }
                return PreviewPane.range(pair[0], pair[1])
            }
            let target = pair(rawTarget), saved = pair(rawRange)
            guard (rawTarget is NSNull || target != nil), composed ? saved == selected && kind == "insertText" : rawRange is NSNull else { return nil }
            version = v
            type = kind
            self.data = data as? String
            selection = saved ?? selected
            self.target = target
            targetVersion = tv
            self.composed = composed
        }
    }

    // WK bridges JS booleans as NSNumber too. Refuse them in integer fields.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return value as? Int
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func range(_ start: Any?, _ end: Any?) -> Range<Int>? {
        guard let lo = integer(start), let hi = integer(end), lo >= 0, hi >= lo else { return nil }
        return lo..<hi
    }

    private func apply(_ input: Input) {
        guard !buffer.isReadOnly, let selection = updater.current(input.selection, at: input.version),
              input.targetVersion >= 0, input.targetVersion <= buffer.version else { return refuse() }
        let target = input.target.flatMap { updater.current($0, at: input.targetVersion) }
        guard input.target == nil || target != nil else { return refuse() }
        let generation = self.generation
        updater.verify(inputType: input.type, data: input.data, selection: selection,
                       target: target) { [weak self] version, edit in
            guard let self, self.generation == generation else { return }
            // A source key may have arrived during verification. Rebase the
            // intent and verify that candidate against the buffer now on screen.
            guard version == self.buffer.version else { return self.apply(input) }
            guard let edit else { return self.refuse() }
            let separateStep = input.composed || !selection.isEmpty || self.updater.pending != nil || edit.pending != nil
            if separateStep { self.buffer.sealUndoStep() }
            do {
                try self.buffer.apply(edit.patch, selectionBefore: selection)
                if separateStep { self.buffer.sealUndoStep() }
                self.waitingForVersion = self.buffer.version
                self.updater.accepted(edit)
            } catch { self.refuse() }
        }
    }

    private func refuse() {
        beep()
        finishInput()
    }

    private func finishInput() {
        waitingForVersion = nil
        inFlight = false
        webView.callAsyncJavaScript("marklight.done()", arguments: [:], in: nil, in: PreviewPane.world)
    }

    /// Route menu commands through the page's input queue. Its unacknowledged
    /// typing belongs before this undo, even when Swift hasn't seen it yet.
    private func menuHistory(redo: Bool) {
        webView.callAsyncJavaScript("""
        document.getElementById('doc').dispatchEvent(new InputEvent('beforeinput', {bubbles:true, cancelable:true, inputType:kind}));
        """, arguments: ["kind": redo ? "historyRedo" : "historyUndo"], in: nil, in: PreviewPane.world)
    }

    private func reject(_ message: WKScriptMessage) {
        rejectedMessages.append("\(message.body)")
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isMain = action.targetFrame?.isMainFrame ?? false
        if pageLoadPending, isMain, action.request.url == location.pageURL {
            pageLoadPending = false
            return decisionHandler(.allow)
        }
        route(action)
        decisionHandler(.cancel)
    }

    /// `target=_blank` lands here. The preview never opens a second web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        route(action)
        return nil
    }

    /// Check the modifier here too: raw HTML can activate an image map or SVG link.
    private func route(_ action: WKNavigationAction) {
        guard action.navigationType == .linkActivated, action.modifierFlags.contains(.command),
              let url = action.request.url else { return }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            openExternal(url)
        case PreviewScheme.name:
            if let file = location.markdownFile(for: url) { openMarkdown(file) }
        default:
            break
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPage()
    }
}

/// `WKUserContentController` holds its handlers strongly, which would keep the pane
/// alive for as long as its own web view.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// The web view's own behavior, where the preview needs something else.
final class PreviewWebView: WKWebView {
    /// The buffer's history, so Cmd-Z works with the preview focused.
    var undoAction: () -> Void = {}
    var redoAction: () -> Void = {}
    var canUndo: () -> Bool = { false }
    var canRedo: () -> Bool = { false }

    /// Context menu items that are safe here. Everything else, such as Open Link,
    /// Download Image, Reload, or anything a later macOS adds, would act outside
    /// the navigation policy (`spikes/spike6-security/REPORT.md`).
    static let allowedMenuItems: Set<String> = [
        "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierCopyImage",
        "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate", "WKMenuItemIdentifierSearchWeb",
        "WKMenuItemIdentifierShareMenu", "WKMenuItemIdentifierSpeechMenu",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        PreviewWebView.filter(menu)
    }

    static func filter(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            if let id = item.identifier?.rawValue, allowedMenuItems.contains(id) { continue }
            menu.removeItem(item)
        }
        // Separators left at the ends or side by side.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
    }

    @objc func undo(_ sender: Any?) { undoAction() }

    @objc func redo(_ sender: Any?) { redoAction() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canUndo()
        case #selector(redo(_:)): return canRedo()
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

/// Shown above the preview when a document has images it isn't loading.
final class RemoteImagesBar: NSBox {
    var load: () -> Void = {}
    let button = NSButton(title: "Load Remote Images", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        boxType = .custom
        fillColor = .controlBackgroundColor
        borderColor = .separatorColor
        borderWidth = 0
        cornerRadius = 0
        titlePosition = .noTitle
        contentViewMargins = NSSize(width: 12, height: 6)
        let label = NSTextField(labelWithString: "Remote images are blocked.")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(clicked)
        let row = NSStackView(views: [label, button])
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        contentView = row
        // An NSBox takes no height from its content.
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    @objc private func clicked() { load() }
}
