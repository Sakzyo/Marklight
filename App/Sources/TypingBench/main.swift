import AppKit
import Foundation
import MarklightCore
import WebKit
@testable import MarklightApp

// Rendered typing on a visible page. `PreviewTimingTests` can't measure this:
// `swift test` never runs AppKit's event loop, so WebKit sees a hidden page. Run:
//
//     MARKLIGHT_BENCH=1 swift run --package-path App -c release -Xswiftc -enable-testing TypingBench
//
// A window floats on screen for a few seconds per size, without taking focus.
// Something else on the desktop can still hide it, and WebKit then restyles the
// whole document, so a run that sees the page's visibility change is thrown away.
// Exits 1 if a target is missed, and 2 if there's no valid measurement.

private final class KeyableWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private let section = """
## A section heading

A paragraph with **bold**, *emphasis*, `code`, and a [link](https://example.com/page) in it, long enough to wrap \
over a couple of lines in a normal window, like most real paragraphs do.

- A list item
- Another list item with `code`
- [ ] A task

```swift
let value = compute(input)
print(value)
```

| Name | Value |
|------|-------|
| a    | 1     |


"""

private let recorder = """
const root = document.querySelector('#doc');
root.focus();
marklight.select(at, at);
const p = getSelection().anchorNode.parentElement.closest('p');
p.scrollIntoView({block: 'center'});
const initial = p.textContent.length;
const now = () => performance.timeOrigin + performance.now();
const record = window.record = {inputs: [], shown: [], frames: [], visibility: []};
document.addEventListener('visibilitychange', () => record.visibility.push(now()));
document.addEventListener('beforeinput', e => { if (e.inputType === 'insertText') record.inputs.push(now()); }, true);
const patch = marklight.patch;
marklight.patch = m => {
    patch(m);
    const delivered = p.textContent.length - initial, end = now();
    while (record.shown.length < delivered) record.shown.push(end);
};
const frame = () => { record.frames.push(now()); requestAnimationFrame(frame); };
requestAnimationFrame(frame);
"""

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

@MainActor private func wait(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}

@MainActor private func wait(timeout: Double, until condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition(), Date() < end { await wait(0.002) }
    return condition()
}

@MainActor private func js(_ web: WKWebView, _ code: String, _ arguments: [String: Any] = [:]) async throws -> Any {
    try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Any, Error>) in
        web.callAsyncJavaScript(code, arguments: arguments, in: nil, in: PreviewPane.world) { reply.resume(with: $0) }
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private struct Interrupted: Error {}

private struct Result {
    let bytes: Int, median: Double, p95: Double, worst: Double, frames: Int
}

@MainActor private func measure(bytes: Int, keys: Int) async throws -> Result {
    let text = String(repeating: section, count: max(1, bytes / section.utf8.count)), source = text as NSString
    let half = source.length / 2
    let at = source.range(of: "A paragraph", options: [], range: NSRange(location: half, length: source.length - half)).location + 5
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("marklight-bench-\(UUID().uuidString).md")
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let doc = try MarkdownDocument(contentsOf: url, ofType: MarkdownDocument.markdownType)
    let controller = EditorWindowController(document: doc, layout: .split, defences: PreviewDefences(), windowClass: KeyableWindow.self)
    doc.addWindowController(controller)
    let window = controller.window!
    defer {
        window.orderOut(nil)
        doc.close()
    }
    // Other windows or another Space would hide it, and WebKit would then hide the page.
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.setContentSize(NSSize(width: 1200, height: 800))
    window.orderFrontRegardless()
    controller.setLayout(.split)
    let pane = controller.preview!, web = pane.webView
    guard await wait(timeout: 60, until: { pane.updater.isCurrent }) else { throw Failure(description: "the page never loaded") }
    window.makeFirstResponder(web)
    _ = try await js(web, recorder, ["at": at])
    // A change of visibility or activation restyles the focused subtree once. Wait it out.
    await wait(3)
    guard try await js(web, "return document.visibilityState") as? String == "visible" else {
        throw Failure(description: "the page isn't visible, so this wouldn't measure anything real")
    }

    var sent: [Double] = []
    var next = ProcessInfo.processInfo.systemUptime
    let letters = ["a", "s", "d", "f"]
    for i in 0..<keys {
        while ProcessInfo.processInfo.systemUptime < next { await wait(0.0005) }
        sent.append(Date().timeIntervalSince1970 * 1000)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, characters: letters[i % 4],
                                              charactersIgnoringModifiers: letters[i % 4], isARepeat: false, keyCode: UInt16(i % 4))!)
        }
        next += 1.0 / 60
    }
    let goal = text.utf16.count + keys
    guard await wait(timeout: 60, until: { doc.buffer.units.count == goal && pane.updater.isCurrent }) else {
        throw Failure(description: "typed keys never arrived at \(bytes) bytes")
    }
    await wait(0.2)
    let json = try await js(web, "return JSON.stringify(window.record)") as? String ?? "{}"
    let record = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [Double]] ?? [:]
    guard record["visibility"]?.isEmpty != false else { throw Interrupted() }
    let shown = record["shown"] ?? [], frames = record["frames"]?.count ?? 0
    guard shown.count == keys else { throw Failure(description: "\(shown.count) of \(keys) keys reached the DOM") }
    guard frames >= keys / 4 else { throw Failure(description: "only \(frames) frames, so the page stopped rendering") }
    let latency = zip(shown, sent).map { $0 - $1 }
    return Result(bytes: bytes, median: percentile(latency, 0.5), p95: percentile(latency, 0.95), worst: latency.max() ?? 0, frames: frames)
}

DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
    print("error: timed out")
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    Task { @MainActor in
        let limits = [100_000: 20.0, 850_000: 50.0]
        var missed = false
        print("Native key dispatch to DOM, 180 keys at 60 a second, visible page")
        print("| Size | Median | p95 | Worst | Frames | Target |")
        print("|---|---:|---:|---:|---:|---|")
        for bytes in [4_000, 30_000, 100_000, 850_000] {
            var result: Result?
            for _ in 0..<4 where result == nil {
                do {
                    result = try await measure(bytes: bytes, keys: 180)
                } catch is Interrupted {
                    print("Discarded a run at \(bytes / 1000) KB: the page's visibility changed")
                } catch {
                    print("error: \(error)")
                    exit(2)
                }
            }
            guard let r = result else {
                print("error: no uninterrupted run at \(bytes / 1000) KB")
                exit(2)
            }
            let target = limits[bytes].map { r.p95 < $0 ? "under \(Int($0)) ms, passed" : "under \(Int($0)) ms, FAILED" } ?? "measured"
            missed = missed || limits[bytes].map { r.p95 >= $0 } ?? false
            print(String(format: "| %d KB | %.1f ms | %.1f ms | %.1f ms | %d | %@ |", bytes / 1000, r.median, r.p95, r.worst, r.frames, target))
        }
        exit(missed ? 1 : 0)
    }
    app.run()
}
