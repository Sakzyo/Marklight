import AppKit
import MarklightCore
import WebKit

/// The security layers that can be turned off. Only the control run in the tests
/// ever does, to show that the tests can see an attack get through.
struct PreviewDefences {
    var contentSecurityPolicy = true
    var pageJavaScriptOff = true
}

/// The rendered pane: a web view showing the buffer, read-only for now.
///
/// Rendered content is untrusted (`docs/plan.md` 2.6). The page runs no script,
/// Marklight's JS lives in an isolated content world, and the page can't navigate.
final class PreviewPane: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "marklight")
    private static let messageHandler = "marklight"
    /// How far back a `selection` message's offsets can be carried.
    private static let patchHistory = 512

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
    private var observer: UUID?
    private var patches: [(version: Int, patch: Patch)] = []
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
        observer = buffer.addObserver { [weak self] patch in self?.remember(patch) }
        loadPage()
    }

    deinit {
        if let observer { buffer.removeObserver(observer) }
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
            code = "marklight.load(list, v)"
            arguments = ["list": blocks.map(block), "v": update.version]
        case .patch(let patch):
            code = "marklight.patch(m)"
            arguments = ["m": ["v": update.version, "from": patch.from, "remove": patch.remove,
                               "list": patch.list.map(block), "delta": patch.delta] as [String: Any]]
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

    private func remember(_ patch: Patch) {
        patches.append((buffer.version, patch))
        if patches.count > PreviewPane.patchHistory { patches.removeFirst(patches.count - PreviewPane.patchHistory) }
    }

    /// Offsets from the page refer to the text it had. Carries them to the buffer's
    /// text, or gives nil if that was too long ago to know.
    private func current(_ offset: Int, at version: Int) -> Int? {
        guard version < buffer.version else { return offset }
        guard let oldest = patches.first?.version, oldest <= version + 1 else { return nil }
        return patches.reduce(offset) { $1.version > version ? $1.patch.transform($0) : $0 }
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
            guard let v = body["v"] as? Int, let start = body["start"] as? Int, let end = body["end"] as? Int,
                  v >= 0, v <= buffer.version, start >= 0, start <= end else { return reject(message) }
            guard let from = current(start, at: v), let to = current(end, at: v), to <= buffer.units.count else { return }
            selectionChanged?(from..<to)
        default:
            reject(message)
        }
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

    /// Only a real click goes anywhere. Meta refreshes and frames are just dropped.
    private func route(_ action: WKNavigationAction) {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return }
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
