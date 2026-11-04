import AppKit
import EditCore
import EditScenarios
import WebKit

// spike3-host: real contenteditable, real key events, same security setup as Spike 6.
//
//   spike3-host [--only <substring>] [--verbose]    run every scenario through WKWebView

let scheme = "marklight-preview"
let pageURL = URL(string: "\(scheme)://doc/")!
let csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src \(scheme): data:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
let pageHTML = """
<!doctype html><html><head><meta charset="utf-8">
<style>#doc { white-space: pre-wrap; font: 14px -apple-system, sans-serif; outline: none; min-height: 100px } pre, code { font-family: Menlo, monospace }</style>
</head><body><main id="doc" contenteditable="true" spellcheck="false"></main></body></html>
"""

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
    var editor = Editor(text: "")
    let world = WKContentWorld.world(name: "marklight")
    var webView: WKWebView!
    var window: KeyWindow!
    var ready: (() -> Void)?
    var messages = 0
    var updatesInFlight = 0
    var inputTypes: [String: Int] = [:]
    var noTargetRanges = 0
    var outcomes: [String: Int] = [:]
    var refusals: [String] = []
    var pendingStart: Date?
    var latencies: [Double] = []

    func setUp(script: String) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: scheme)
        config.userContentController.add(self, contentWorld: world, name: "marklight")
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = self
        window = KeyWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = webView
        window.orderFrontRegardless()
        window.makeFirstResponder(webView)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": csp,
        ])!
        task.didReceive(response)
        task.didReceive(Data(pageHTML.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        messages += 1
        let start = body["start"] as? Int ?? 0
        let end = body["end"] as? Int ?? start
        let sel = start..<max(start, end)
        switch type {
        case "ready":
            ready?()
        case "input":
            let inputType = body["inputType"] as? String ?? "?"
            inputTypes[inputType, default: 0] += 1
            guard let command = command(inputType, data: body["data"] as? String, sel: sel, target: body["target"] as? [Int]) else { return }
            apply(command)
        case "toggle":
            let kind = MarkKind(rawValue: body["kind"] as? String ?? "") ?? .strong
            apply(.toggle(kind, sel))
        case "checkbox":
            apply(.checkbox(at: body["at"] as? Int ?? 0), caret: sel)
        case "paste":
            if let raw = body["blocks"] as? [[String: Any]] {
                apply(.pasteRich(raw.map(pasteBlock), sel))
            } else {
                apply(.pastePlain(body["plain"] as? String ?? "", sel))
            }
        default:
            break
        }
    }

    func pasteBlock(_ raw: [String: Any]) -> PasteBlock {
        let name = raw["kind"] as? String ?? "paragraph"
        let kind: PasteBlock.Kind
        switch name {
        case "bullet": kind = .bullet
        case "ordered": kind = .ordered
        case "quote": kind = .quote
        case "code": kind = .code
        case let h where h.hasPrefix("h"): kind = .heading(Int(h.dropFirst()) ?? 1)
        default: kind = .paragraph
        }
        let runs = (raw["runs"] as? [[String: Any]] ?? []).map {
            PasteRun($0["text"] as? String ?? "", marks: $0["marks"] as? [String] ?? [], href: $0["href"] as? String)
        }
        return PasteBlock(kind, runs)
    }

    func command(_ inputType: String, data: String?, sel: Range<Int>, target: [Int]?) -> Command? {
        let t = target.map { $0[0]..<max($0[0], $0[1]) }
        switch inputType {
        case "insertText", "insertReplacementText":
            return .insert(data ?? "", inputType == "insertReplacementText" ? (t ?? sel) : sel)
        case "insertParagraph": return .enter(sel)
        case "insertLineBreak": return .lineBreak(sel)
        case "deleteContentBackward", "deleteContentForward":
            // Collapsed: Swift finds the grapheme and handles block edges.
            return .delete(sel, backward: inputType.hasSuffix("Backward"))
        case "deleteWordBackward", "deleteWordForward", "deleteSoftLineBackward", "deleteSoftLineForward",
             "deleteHardLineBackward", "deleteHardLineForward", "deleteByCut", "deleteContent":
            if !sel.isEmpty { return .delete(sel, backward: true) }
            if t == nil || t!.isEmpty { noTargetRanges += 1 }
            return .delete(t ?? sel, backward: inputType.hasSuffix("Backward"))
        case "formatBold": return .toggle(.strong, sel)
        case "formatItalic": return .toggle(.em, sel)
        default:
            refusals.append("unhandled inputType \(inputType)")
            return nil
        }
    }

    func apply(_ command: Command, caret: Range<Int>? = nil) {
        let outcome = editor.perform(command)
        outcomes[outcome.path.rawValue, default: 0] += 1
        if outcome.path == .refused { refusals.append(outcome.note) }
        show(caret: caret ?? outcome.caret..<outcome.caret)
        if let s = pendingStart {
            latencies.append(Date().timeIntervalSince(s) * 1000)
            pendingStart = nil
        }
    }

    func show(caret: Range<Int>) {
        updatesInFlight += 1
        let html = Renderer.html(editor.doc, pending: editor.pending)
        webView.callAsyncJavaScript("marklight.update(html, start, end)",
                                    arguments: ["html": html, "start": caret.lowerBound, "end": caret.upperBound],
                                    in: nil, in: world) { [weak self] _ in self?.updatesInFlight -= 1 }
    }

    func visualCaret(_ offset: Int) -> Int {
        guard let leaf = editor.doc.root.allLeaves().first(where: { $0.content.lowerBound <= offset && offset <= $0.content.upperBound }),
              offset == leaf.content.upperBound, let last = leaf.atoms.last?.range else { return offset }
        return last.upperBound
    }

    func js<T>(_ code: String, _ args: [String: Any] = [:]) async -> T? {
        try? await webView.callAsyncJavaScript(code, arguments: args, in: nil, contentWorld: world) as? T
    }

    func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        pendingStart = Date()
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            window.sendEvent(e)
        }
    }

    func click(x: Double, y: Double) {
        let p = NSPoint(x: x, y: webView.bounds.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            // Mouse events sent through the window don't reach an unactivated web view.
            if type == .leftMouseDown { webView.mouseDown(with: e) } else { webView.mouseUp(with: e) }
        }
    }

    /// Waits for the page to go quiet after an input event.
    func settle() async {
        var last = -1
        var stable = 0
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if messages == last, updatesInFlight == 0 { stable += 1 } else { stable = 0 }
            last = messages
            if stable >= 4 { return }
        }
    }

    func perform(_ action: Action) async {
        switch action {
        case .type(let text):
            for ch in text {
                key(String(ch), code: 0)
                await settle()
            }
        case .backspace, .deleteSelection:
            key("\u{7F}", code: 51)
            await settle()
        case .forwardDelete:
            key("\u{F728}", code: 117)
            await settle()
        case .enter:
            key("\r", code: 36)
            await settle()
        case .shiftEnter:
            key("\r", code: 36, flags: .shift)
            await settle()
        case .toggle(let kind):
            switch kind {
            case .strong: key("b", code: 11, flags: .command)
            case .em: key("i", code: 34, flags: .command)
            case .code: key("e", code: 14, flags: .command)
            case .strike:
                // No shortcut in the spike: the app's menu would read the selection and send this.
                if let s: [Int] = await js("return marklight.selection()") { apply(.toggle(.strike, s[0]..<s[1])) }
            }
            await settle()
        case .heading(let n):
            if let s: [Int] = await js("return marklight.selection()") { apply(.heading(n, at: s[0])) }
            await settle()
        case .checkbox:
            if let s: [Int] = await js("return marklight.selection()"),
               let at: [NSNumber] = await js("return marklight.rectOf(at)", ["at": s[0]]) {
                click(x: at[0].doubleValue, y: at[1].doubleValue)
            }
            await settle()
        case .pastePlain(let text):
            let _: Bool? = await js("marklight.paste(text, null); return true", ["text": text])
            await settle()
        case .pasteRich(let blocks):
            let _: Bool? = await js("marklight.paste(text, html); return true", ["text": "x", "html": html(blocks)])
            await settle()
        }
    }

    func html(_ blocks: [PasteBlock]) -> String {
        func inline(_ runs: [PasteRun]) -> String {
            runs.map { run in
                var s = run.text
                for m in run.marks.reversed() { s = "<\(m == "strong" ? "b" : m == "em" ? "i" : m)>\(s)</\(m == "strong" ? "b" : m == "em" ? "i" : m)>" }
                if let h = run.href { s = "<a href=\"\(h)\">\(s)</a>" }
                return s
            }.joined()
        }
        var out = ""
        var inList = false
        for b in blocks {
            if inList, b.kind != .bullet { out += "</ul>"; inList = false }
            switch b.kind {
            case .paragraph: out += "<p>\(inline(b.runs))</p>"
            case .heading(let n): out += "<h\(n)>\(inline(b.runs))</h\(n)>"
            case .bullet:
                if !inList { out += "<ul>"; inList = true }
                out += "<li>\(inline(b.runs))</li>"
            case .ordered: out += "<ol><li>\(inline(b.runs))</li></ol>"
            case .quote: out += "<blockquote>\(inline(b.runs))</blockquote>"
            case .code: out += "<pre>\(inline(b.runs))</pre>"
            }
        }
        return out + (inList ? "</ul>" : "")
    }
}

@MainActor func run() async {
    let only = CommandLine.arguments.firstIndex(of: "--only").map { CommandLine.arguments[$0 + 1] }
    let verbose = CommandLine.arguments.contains("--verbose")
    let purify = try! String(contentsOf: Bundle.module.url(forResource: "purify.min", withExtension: "js", subdirectory: "Resources")!, encoding: .utf8)
    let bridge = try! String(contentsOf: Bundle.module.url(forResource: "bridge", withExtension: "js", subdirectory: "Resources")!, encoding: .utf8)
    let host = Host()
    host.setUp(script: purify + "\n" + bridge)
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        host.ready = { c.resume() }
        host.webView.load(URLRequest(url: pageURL))
    }

    var passed = 0, failed: [String] = [], unreachable: [String] = []
    for s in allScenarios where only.map({ s.name.contains($0) }) ?? true {
        let (text, selection) = parseMarkers(s.before)
        let (expected, expectedCaret) = parseMarkers(s.after)
        host.editor = Editor(text: text)
        host.show(caret: selection)
        await host.settle()
        let actual: [Int] = await host.js("return marklight.selection()") ?? []
        if actual != [selection.lowerBound, selection.upperBound] {
            unreachable.append("\(s.name): wanted \(selection), DOM gives \(actual)")
        }
        for action in s.actions { await host.perform(action) }
        let caret: [Int] = await host.js("return marklight.selection()") ?? []
        let outline = Outline.of(host.editor.doc.root)
        let textOK = host.editor.text.utf8.elementsEqual(expected.utf8)
        // A caret between a closing delimiter and the end of its block has no DOM
        // position of its own; it shows at the end of the text.
        let visual = host.visualCaret(expectedCaret.lowerBound)
        let caretOK = caret == [expectedCaret.lowerBound, expectedCaret.upperBound] || caret == [visual, visual]
        if textOK, outline == s.outline, caretOK {
            passed += 1
            if verbose { print("ok   \(s.name)") }
        } else {
            failed.append("\(s.name)\n     got  \(host.editor.text.debugDescription) \(outline) caret \(caret)\n     want \(expected.debugDescription) \(s.outline) caret \(expectedCaret)")
        }
    }
    print("scenarios through WKWebView: \(passed) passed, \(failed.count) failed")
    for f in failed { print("FAIL \(f)") }
    print("\nselection not reachable before the action (\(unreachable.count)):")
    for u in unreachable { print("  \(u)") }
    print("\ninputTypes seen: \(host.inputTypes.sorted { $0.key < $1.key })")
    print("outcomes: \(host.outcomes.sorted { $0.key < $1.key })")
    print("refusals: \(Dictionary(grouping: host.refusals) { $0 }.mapValues { $0.count })")
    if !host.latencies.isEmpty {
        let sorted = host.latencies.sorted()
        print(String(format: "key event to document updated: median %.2f ms, p95 %.2f ms", sorted[sorted.count / 2], sorted[sorted.count * 95 / 100]))
    }
}

NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    await run()
    exit(0)
}
NSApplication.shared.run()
