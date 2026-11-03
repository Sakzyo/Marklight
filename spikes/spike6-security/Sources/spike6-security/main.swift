import AppKit
import Markdown
import WebKit

// spike6-security: render a hostile Markdown file in a WKWebView under several
// combinations of defences and report what got through.
//
//   spike6-security            run everything and print Markdown tables

let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
let evilSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" onload="parent.document.title='pwned-svg-img-onload'">\
<script>parent.document.title='pwned-svg-img-script'</script><rect width="10" height="10" fill="red"/></svg>
"""

/// <tmp>/secret/secret.png, <tmp>/repo/{.git, assets/shared.png, docs/...}. The document folder is repo/docs.
func makeTree() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("spike6-\(UUID().uuidString)")
    let docs = root.appendingPathComponent("repo/docs")
    for dir in ["secret", "repo/.git", "repo/assets", "repo/docs/images/sub"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in ["secret/secret.png", "repo/assets/shared.png", "repo/docs/images/ok.png",
                 "repo/docs/images/sub/nested.png", "repo/docs/images/with space.png"] {
        try onePixelPNG.write(to: root.appendingPathComponent(file))
    }
    try Data(evilSVG.utf8).write(to: docs.appendingPathComponent("images/evil.svg"))
    try Data("not an image".utf8).write(to: docs.appendingPathComponent("notes.txt"))
    try Data("# Other\n".utf8).write(to: docs.appendingPathComponent("other.md"))
    try fm.createSymbolicLink(atPath: docs.appendingPathComponent("link-in.png").path, withDestinationPath: "images/ok.png")
    try fm.createSymbolicLink(atPath: docs.appendingPathComponent("link-out.png").path, withDestinationPath: "../../secret/secret.png")
    return docs
}

struct RunResult {
    let defences: Defences
    let state: [String: Any]
    let pageWorld: [String]
    let titleAfterClicks: String
    let stillOnPage: Bool
    let controller: PreviewController
    let handler: PreviewSchemeHandler
}

@MainActor func sleep(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

let linkTexts = ["html js link", "html data link", "markdown js link", "attribute breakout", "external link",
                 "target blank link", "mail link", "other markdown file", "anchor link"]

@MainActor func run(_ defences: Defences, html: String, docs: URL, purify: String) async throws -> RunResult {
    let controller = PreviewController()
    let handler = PreviewSchemeHandler(policy: PathPolicy(documentFolder: docs), page: { pageHTML })
    handler.cspEnabled = defences.csp
    let world = WKContentWorld.world(name: "marklight")

    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(handler, forURLScheme: PreviewScheme.name)
    config.userContentController.add(controller, contentWorld: world, name: "marklight")
    config.userContentController.addUserScript(WKUserScript(source: purify + "\n" + isolatedScriptGlue, injectionTime: .atDocumentEnd,
                                                            forMainFrameOnly: true, in: world))
    config.defaultWebpagePreferences.allowsContentJavaScript = defences.contentJS
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.websiteDataStore = .nonPersistent()

    let frame = NSRect(x: 0, y: 0, width: 900, height: 1800)
    let webView = WKWebView(frame: frame, configuration: config)
    webView.navigationDelegate = controller
    webView.uiDelegate = controller
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0 // invisible, but real events still reach the web view
    window.contentView = webView
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        var resumed = false
        controller.onReady = { if !resumed { resumed = true; done.resume() } }
        webView.load(URLRequest(url: PreviewScheme.pageURL))
        Task { @MainActor in await sleep(10); if !resumed { resumed = true; print("warning: no ready message"); done.resume() } }
    }

    _ = try await webView.callAsyncJavaScript("marklight.render(html, sanitize)", arguments: ["html": html, "sanitize": defences.sanitize],
                                              in: nil, contentWorld: world)
    await sleep(1.5)
    let stateJSON = try await webView.callAsyncJavaScript("return marklight.state()", in: nil, contentWorld: world) as? String ?? "{}"
    let state = (try? JSONSerialization.jsonObject(with: Data(stateJSON.utf8))) as? [String: Any] ?? [:]

    // What can the page's own world see?
    let probe = "JSON.stringify([String(window.__pwned), typeof window.webkit, typeof DOMPurify, typeof marklight])"
    let pageWorldJSON = (try? await webView.evaluateJavaScript(probe, in: nil, contentWorld: .page) as? String) ?? "[\"probe failed\"]"
    let pageWorld = (try? JSONSerialization.jsonObject(with: Data(pageWorldJSON.utf8))) as? [String] ?? []

    // Real mouse clicks on each link.
    var stillOnPage = true
    for text in linkTexts {
        guard let rect = try await webView.callAsyncJavaScript("return marklight.rectOf(text)", arguments: ["text": text],
                                                               in: nil, contentWorld: world) as? [Double] else { continue }
        await sleep(0.2)
        let point = NSPoint(x: rect[0], y: webView.bounds.height - rect[1])
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        await sleep(0.6)
        if webView.url?.absoluteString.hasPrefix(PreviewScheme.pageURL.absoluteString) != true { stillOnPage = false }
    }
    let titleAfter = (try? await webView.evaluateJavaScript("document.title", in: nil, contentWorld: world) as? String) ?? ""

    return RunResult(defences: defences, state: state, pageWorld: pageWorld, titleAfterClicks: titleAfter,
                     stillOnPage: stillOnPage, controller: controller, handler: handler)
}

@MainActor func main() async {
    do {
        let docs = try makeTree()
        defer { try? FileManager.default.removeItem(at: docs.deletingLastPathComponent().deletingLastPathComponent()) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/attack.md").standardized
        let markdown = try String(contentsOf: fixture, encoding: .utf8)
        let html = HTMLFormatter.format(Document(parsing: markdown, options: [.disableSmartOpts]))
        let purifyURL = Bundle.module.url(forResource: "purify.min", withExtension: "js", subdirectory: "Resources")!
        let purify = try String(contentsOf: purifyURL, encoding: .utf8)

        if CommandLine.arguments.contains("--html") { print(html); return }
        if CommandLine.arguments.contains("--probe") {
            for mode in [Defences(sanitize: true, csp: false, contentJS: true), Defences(sanitize: true, csp: true, contentJS: true),
                         Defences(sanitize: true, csp: false, contentJS: false)] {
                do { _ = try await run(mode, html: "<p>x</p>", docs: docs, purify: purify); print("\(mode): ok") }
                catch { print("\(mode): \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? error)") }
            }
            return
        }

        printPolicyTable(docs: docs)
        let modes = [
            Defences(sanitize: true, csp: true, contentJS: false),
            Defences(sanitize: false, csp: true, contentJS: true),
            Defences(sanitize: false, csp: false, contentJS: false),
            Defences(sanitize: true, csp: false, contentJS: true),
            Defences(sanitize: false, csp: false, contentJS: true),
        ]
        var results: [RunResult] = []
        for mode in modes {
            do { results.append(try await run(mode, html: html, docs: docs, purify: purify)) }
            catch { print("\n**\(mode) failed:** \(error.localizedDescription) \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? "")") }
        }
        guard !results.isEmpty else { return }
        printResults(results)
    } catch {
        print("error: \(error)")
    }
}

NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    await main()
    exit(0)
}
NSApplication.shared.run()
