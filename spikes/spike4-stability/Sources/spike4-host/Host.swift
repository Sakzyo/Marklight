import AppKit
import EditCore
import EditScenarios
import WebKit

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

final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler, NSTextStorageDelegate {
    var editor = Editor(text: "")
    let world = WKContentWorld.world(name: "marklight")
    var webView: WKWebView!
    var textView: NSTextView!
    var scrollView: NSScrollView!
    var window: KeyWindow!
    var ready: (() -> Void)?
    var messages = 0
    var refusals: [String] = []
    var onChange: ((Patch) -> Void)?

    // Parsing can take longer than the gap between keys, and the main thread is
    // what forwards keys to the page. So the editor and everything derived from
    // it live on this queue; the main thread only moves results around.
    let queue = DispatchQueue(label: "marklight.editor")
    var sent: [RenderedBlock] = [] // on `queue`
    var sentVersion = 0            // on `queue`

    // Main thread.
    var syncing = false
    var wanted: (caret: Range<Int>?, local: Bool, ack: Bool)?
    var work = 0                   // edits handed to `queue` and not yet back
    var sourceLog: [Patch] = []    // every source-pane edit, in order
    var dirty = false

    // Origin tagging: true while Swift itself is writing to the source pane.
    var applyingToSourcePane = false
    var sourceEdits = 0
    var sourceMirrors = 0
    var renderedRenders = 0
    var sourceApplied = 0          // on `queue`

    func setUp(script: String) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: scheme)
        config.userContentController.add(self, contentWorld: world, name: "marklight")
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let frame = NSRect(x: 0, y: 0, width: 1400, height: 700)
        window = KeyWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        let content = NSView(frame: frame)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 700), configuration: config)
        webView.navigationDelegate = self
        content.addSubview(webView)
        textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 700)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textStorage?.delegate = self
        scrollView = NSScrollView(frame: NSRect(x: 700, y: 0, width: 700, height: 700))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        content.addSubview(scrollView)
        window.contentView = content
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

    // MARK: - Source pane

    /// Every text change in the source pane comes through here. Swift's own
    /// writes are tagged, which is what stops a patch from echoing back.
    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), !applyingToSourcePane else { return }
        let old = range.location..<(range.location + range.length - delta)
        let new = Array(storage.string.utf16[storage.string.utf16.index(storage.string.utf16.startIndex, offsetBy: range.location)..<storage.string.utf16.index(storage.string.utf16.startIndex, offsetBy: range.location + range.length)])
        sourceEdits += 1
        sourceLog.append(Patch(range: old, replacement: new, origin: .source))
        work += 1
        queue.async { [self] in
            editor.applyExternal(old, new)
            sourceApplied += 1
            DispatchQueue.main.async { [self] in
                work -= 1
                sync()
            }
        }
    }

    /// Applies a rendered-pane patch to the source pane, leaving its caret and scroll alone.
    func mirror(_ original: Patch, sourceBase: Int) {
        guard let storage = textView.textStorage else { return }
        sourceMirrors += 1
        // Keys typed in the source pane since this edit started are already in
        // the text view, so carry the patch across them.
        var lo = original.range.lowerBound, hi = original.range.upperBound
        for edit in sourceLog[sourceBase...] {
            lo = Editor.transform(lo, through: edit)
            hi = Editor.transform(hi, through: edit)
        }
        let patch = Patch(range: lo..<max(lo, hi), replacement: original.replacement, origin: original.origin)
        applyingToSourcePane = true
        let selection = textView.selectedRanges.map { $0.rangeValue }
        let origin = scrollView.contentView.bounds.origin
        let carried = selection.map { r -> NSValue in
            let lo = Editor.transform(r.location, through: patch)
            let hi = Editor.transform(r.location + r.length, through: patch)
            return NSValue(range: NSRange(location: lo, length: hi - lo))
        }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: patch.range.lowerBound, length: patch.range.count),
                                  with: String(decoding: patch.replacement, as: UTF16.self))
        storage.endEditing()
        textView.selectedRanges = carried
        scrollView.contentView.scroll(to: origin)
        applyingToSourcePane = false
    }

    // MARK: - Rendered pane

    func load(_ text: String, selection: Range<Int>?) async {
        editor = Editor(text: text)
        applyingToSourcePane = true
        textView.string = text
        applyingToSourcePane = false
        sourceLog = []
        sourceApplied = 0
        let list = Renderer.blocks(editor.doc)
        sent = list
        sentVersion = editor.version
        let payload = list.map { ["html": $0.html, "base": $0.base] as [String: Any] }
        let _: Bool? = await js("marklight.load(list, v, start, end); return true", [
            "list": payload, "v": editor.version, "start": selection?.lowerBound ?? NSNull(), "end": selection?.upperBound ?? NSNull(),
        ])
    }

    /// Runs on `queue`. Diffs against what was last sent, so edits made while a
    /// sync is running collapse into the next one.
    private func diff(caret: Range<Int>?, local: Bool) -> [String: Any] {
        let list = Renderer.blocks(editor.doc, pending: editor.pending)
        var head = 0
        while head < sent.count, head < list.count, sent[head] == list[head] { head += 1 }
        var tail = 0
        var delta = 0
        if let a = sent.last, let b = list.last { delta = b.base - a.base }
        while tail < sent.count - head, tail < list.count - head,
              sent[sent.count - 1 - tail].html == list[list.count - 1 - tail].html,
              list[list.count - 1 - tail].base - sent[sent.count - 1 - tail].base == delta { tail += 1 }
        let middle = list[head..<(list.count - tail)]
        let message: [String: Any] = [
            "v": editor.version, "from": head, "remove": sent.count - head - tail,
            "list": middle.map { ["html": $0.html, "base": $0.base] as [String: Any] },
            "delta": tail > 0 ? delta : 0, "local": local,
            "caret": caret.map { [$0.lowerBound, $0.upperBound] } ?? NSNull(),
            "edits": editor.edits(since: sentVersion),
        ]
        sent = list
        sentVersion = editor.version
        return message
    }

    /// Brings the DOM up to date, one patch at a time.
    func sync(caret: Range<Int>? = nil, local: Bool = false, ack: Bool = false) {
        if syncing {
            wanted = (caret ?? wanted?.caret, local || (wanted?.local ?? false), ack || (wanted?.ack ?? false))
            return
        }
        syncing = true
        renderedRenders += 1
        queue.async { [self] in
            let message = diff(caret: caret, local: local)
            DispatchQueue.main.async { [self] in
                let code = ack ? "marklight.patch(m); marklight.done(); return true" : "marklight.patch(m); return true"
                webView.callAsyncJavaScript(code, arguments: ["m": message], in: nil, in: world) { [weak self] result in
                    guard let self else { return }
                    if case .failure(let e) = result { print("patch failed: \(e)") }
                    syncing = false
                    if let w = wanted {
                        wanted = nil
                        sync(caret: w.caret, local: w.local, ack: w.ack)
                    }
                }
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        messages += 1
        if type == "ready" { ready?(); return }
        let v = body["v"] as? Int ?? 0
        work += 1
        queue.async { [self] in
            // The page may not have seen the latest source-pane edits.
            let lo = editor.rebase(body["start"] as? Int ?? 0, from: v)
            let hi = editor.rebase(body["end"] as? Int ?? 0, from: v)
            let sel = lo..<max(lo, hi)
            var command: Command?
            var keepCaret = false
            switch type {
            case "input":
                var target: Range<Int>?
                if let t = body["target"] as? [Int], t.count == 2 {
                    let from = body["targetV"] as? Int ?? v
                    let a = editor.rebase(t[0], from: from), b = editor.rebase(t[1], from: from)
                    target = a..<max(a, b)
                }
                command = self.command(body["inputType"] as? String ?? "", data: body["data"] as? String, sel: sel, target: target)
            case "toggle":
                command = .toggle(MarkKind(rawValue: body["kind"] as? String ?? "") ?? .strong, sel)
            case "checkbox":
                command = .checkbox(at: editor.rebase(body["checkbox"] as? Int ?? 0, from: v))
                keepCaret = true
            case "paste":
                if let raw = body["blocks"] as? [[String: Any]] {
                    command = .pasteRich(raw.map(pasteBlock), sel)
                } else {
                    command = .pastePlain(body["plain"] as? String ?? "", sel)
                }
            default:
                break
            }
            guard let command else {
                DispatchQueue.main.async { [self] in
                    work -= 1
                    sync(ack: true)
                }
                return
            }
            finish(command, caret: keepCaret ? sel : nil, ack: true)
        }
    }

    /// Runs on `queue`.
    private func finish(_ command: Command, caret: Range<Int>?, ack: Bool) {
        let outcome = editor.perform(command)
        let base = sourceApplied
        DispatchQueue.main.async { [self] in
            work -= 1
            if outcome.path == .refused { refusals.append(outcome.note) }
            if let patch = outcome.patch { mirror(patch, sourceBase: base) }
            sync(caret: caret ?? outcome.caret..<outcome.caret, local: true, ack: ack)
        }
    }

    func apply(_ command: Command, caret: Range<Int>? = nil, ack: Bool = false) {
        work += 1
        queue.async { [self] in finish(command, caret: caret, ack: ack) }
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

    func command(_ inputType: String, data: String?, sel: Range<Int>, target: Range<Int>?) -> Command? {
        switch inputType {
        case "insertText", "insertReplacementText":
            return .insert(data ?? "", inputType == "insertReplacementText" ? (target ?? sel) : sel)
        case "insertParagraph": return .enter(sel)
        case "insertLineBreak": return .lineBreak(sel)
        case "deleteContentBackward", "deleteContentForward":
            return .delete(sel, backward: inputType.hasSuffix("Backward"))
        case "deleteWordBackward", "deleteWordForward", "deleteSoftLineBackward", "deleteSoftLineForward",
             "deleteHardLineBackward", "deleteHardLineForward", "deleteByCut", "deleteContent":
            if !sel.isEmpty { return .delete(sel, backward: true) }
            return .delete(target ?? sel, backward: inputType.hasSuffix("Backward"))
        case "formatBold": return .toggle(.strong, sel)
        case "formatItalic": return .toggle(.em, sel)
        default:
            refusals.append("unhandled inputType \(inputType)")
            return nil
        }
    }

    func js<T>(_ code: String, _ args: [String: Any] = [:]) async -> T? {
        do {
            return try await webView.callAsyncJavaScript(code, arguments: args, in: nil, contentWorld: world) as? T
        } catch {
            print("js failed: \(error) in \(code.prefix(60))")
            return nil
        }
    }

    /// The DOM against a fresh render, or a description of the first difference.
    func verifyDOM() async -> String? {
        let list = Renderer.blocks(editor.doc, pending: editor.pending)
        return await js("return marklight.verify(list)", ["list": list.map { ["html": $0.html, "base": $0.base] as [String: Any] }])
    }

    func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
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
            if type == .leftMouseDown { webView.mouseDown(with: e) } else { webView.mouseUp(with: e) }
        }
    }

    /// Waits for the page to go quiet after an input event.
    func settle() async {
        var stable = 0
        var last = -1
        for _ in 0..<600 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            let idle: Bool? = await js("return marklight.idle()")
            if idle == true, !syncing, wanted == nil, work == 0, messages == last { stable += 1 } else { stable = 0 }
            last = messages
            if stable >= 3 { return }
        }
        print("warning: page never settled")
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

    func visualCaret(_ offset: Int) -> Int {
        guard let leaf = editor.doc.root.allLeaves().first(where: { $0.content.lowerBound <= offset && offset <= $0.content.upperBound }),
              offset == leaf.content.upperBound, let last = leaf.atoms.last?.range else { return offset }
        return last.upperBound
    }
}
