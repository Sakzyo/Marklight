import AppKit
import Foundation
import MarklightCore
import Testing
import WebKit
@testable import MarklightApp

let fixturesFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures")

let previewFixtureNames = ((try? FileManager.default.contentsOfDirectory(atPath: fixturesFolder.path)) ?? [])
    .filter { !$0.hasPrefix(".") }.sorted()

/// A temporary folder with its real path, so it can be compared with `realpath`.
func makeTemporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("marklight-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingFileSymlinks()
}

/// Runs the main thread until `condition` holds or the time is up. WebKit needs a
/// real run loop, which `swift test` doesn't guarantee, and the main queue only
/// drains when this test gives up the main actor, so it has to do both.
@MainActor func pump(until condition: () -> Bool, timeout: Double = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        spinRunLoop()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

@MainActor private func spinRunLoop() {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
}

@MainActor func pump(for seconds: Double) async {
    _ = await pump(until: { false }, timeout: seconds)
}

/// Every suite that opens a web view, so they run one at a time. On top of each
/// other they fight over the main thread, and a pause in one upsets another's timing.
@Suite("Preview", .serialized) enum PreviewSuites {}

struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

/// Harnesses open now. `swift test` runs on Swift's async main, which calls
/// `exit(0)` if anything stops the main run loop, and the test run then ends early
/// and reports success with no summary. `NSButton.performClick` does exactly that,
/// so use `sendAction` in tests. An exit with a test still open is turned into a
/// failure that can't be missed.
nonisolated(unsafe) private var openHarnesses = 0

private let failOnEarlyExit: Void = {
    atexit {
        guard openHarnesses > 0 else { return }
        fputs("error: the test process exited with \(openHarnesses) preview tests still running\n", stderr)
        _exit(70)
    }
}()

/// A document in a real window with a real preview. The window is on screen but
/// invisible, so layout and mouse events are real. Hold on to this for the whole
/// test: a document that's been discarded is freed while its work is still going.
@MainActor final class PreviewHarness {
    let doc: MarkdownDocument
    let controller: EditorWindowController
    var pane: PreviewPane { controller.preview! }
    var webView: PreviewWebView { pane.webView }
    var textView: SourceTextView { controller.editor.textView }
    var window: NSWindow { controller.window! }

    init(url: URL, layout: PaneLayout = .split, size: NSSize = NSSize(width: 1000, height: 700),
         defences: PreviewDefences = PreviewDefences(), windowClass: NSWindow.Type = NSWindow.self) throws {
        _ = NSApplication.shared
        _ = failOnEarlyExit
        doc = try MarkdownDocument(contentsOf: url, ofType: MarkdownDocument.markdownType)
        controller = EditorWindowController(document: doc, layout: layout, defences: defences, windowClass: windowClass)
        doc.addWindowController(controller)
        openHarnesses += 1
        controller.window!.alphaValue = 0
        controller.window!.setContentSize(size)
        controller.window!.orderFrontRegardless()
        controller.setLayout(layout)
    }

    convenience init(text: String, name: String = "doc.md", layout: PaneLayout = .split, size: NSSize = NSSize(width: 1000, height: 700),
                     windowClass: NSWindow.Type = NSWindow.self) throws {
        let folder = try makeTemporaryFolder()
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try self.init(url: url, layout: layout, size: size, windowClass: windowClass)
    }

    func close() {
        window.orderOut(nil)
        doc.close()
        PaneLayout.forget()
        openHarnesses -= 1
    }

    /// Waits for the page to show the buffer's text. A failure here is a real one:
    /// without it, a later check could pass against an old or empty DOM.
    func settle(timeout: Double = 20) async throws {
        guard await pump(until: { self.pane.updater.isCurrent }, timeout: timeout) else {
            throw HarnessFailure(description: "the preview never caught up, version \(doc.buffer.version)")
        }
    }

    /// Runs JS in Marklight's isolated world, and returns what it returns.
    func js(_ code: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        var outcome: Result<Any, Error>?
        webView.callAsyncJavaScript(code, arguments: arguments, in: nil, in: PreviewPane.world) { outcome = $0 }
        guard await pump(until: { outcome != nil }) else { throw HarnessFailure(description: "no answer from: \(code)") }
        return try outcome!.get()
    }

    /// Evaluates an expression in the page's own world, where a document's script would run.
    func pageWorld(_ code: String) async throws -> Any? {
        var outcome: Result<Any, Error>?
        webView.evaluateJavaScript(code, in: nil, in: .page) { outcome = $0 }
        guard await pump(until: { outcome != nil }) else { throw HarnessFailure(description: "no answer from: \(code)") }
        return try outcome!.get()
    }

    func json<T>(_ code: String, _ arguments: [String: Any] = [:]) async throws -> T {
        let text = try await js("return JSON.stringify((() => { \(code) })())", arguments) as? String ?? "null"
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) as? T else {
            throw HarnessFailure(description: "unexpected result \(text)")
        }
        return value
    }

    /// The whole DOM of the document, node by node, with each block's offset. A
    /// serialized string wouldn't show text split across two nodes. Blocks are
    /// listed flat: which wrapper holds a block depends on the edit history.
    func dom() async throws -> String {
        try await js("""
        const dump = n => n.nodeType === 1
          ? [n.nodeName, [...n.attributes].map(a => [a.name, a.value]).sort(), [...n.childNodes].map(dump)]
          : [n.nodeType, n.nodeValue];
        const blocks = [...document.getElementById('doc').childNodes].flatMap(chunk => chunk.nodeType === 1 ? [...chunk.childNodes] : [chunk]);
        return JSON.stringify(blocks.map(el => [el._base, dump(el)]));
        """) as? String ?? ""
    }

    /// Replaces the page with a whole fresh render of the current text.
    func freshRender() async throws {
        pane.updater.pageReady()
        try await settle()
    }

    /// A real mouse click, or a drag if `to` is given, at page coordinates. Sent to
    /// the view rather than the window: this process is never the active app, and
    /// a window that isn't key swallows a plain first click.
    func click(x: Double, y: Double, to end: (x: Double, y: Double)? = nil, modifiers: NSEvent.ModifierFlags = []) async {
        func point(_ x: Double, _ y: Double) -> NSPoint {
            webView.convert(NSPoint(x: x, y: y), to: nil)
        }
        func send(_ type: NSEvent.EventType, _ at: NSPoint) {
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: webView.mouseDown(with: event)
            case .leftMouseDragged: webView.mouseDragged(with: event)
            default: webView.mouseUp(with: event)
            }
        }
        send(.leftMouseDown, point(x, y))
        if let end {
            await pump(for: 0.05)
            send(.leftMouseDragged, point(end.x, end.y))
            await pump(for: 0.05)
            send(.leftMouseUp, point(end.x, end.y))
        } else {
            send(.leftMouseUp, point(x, y))
        }
    }

    /// The middle of the first element matching `selector`, scrolled into view.
    func center(of selector: String, text: String? = nil) async throws -> (x: Double, y: Double) {
        let box: [Double] = try await json("""
        const list = [...document.querySelectorAll(selector)];
        const el = text === null ? list[0] : list.find(e => e.textContent === text);
        if (!el) return [];
        el.scrollIntoView({ block: 'center' });
        const r = el.getClientRects()[0]; // the first line, as a link can wrap
        return [r.left + Math.min(r.width / 2, 20), r.top + r.height / 2];
        """, ["selector": selector, "text": text as Any? ?? NSNull()])
        guard box.count == 2 else { throw HarnessFailure(description: "nothing matches \(selector) \(text ?? "")") }
        return (box[0], box[1])
    }
}

extension PaneLayout {
    /// So one test's layout doesn't become the next test's default.
    static func forget() { UserDefaults.standard.removeObject(forKey: defaultsKey) }
}
