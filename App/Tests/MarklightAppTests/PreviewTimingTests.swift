import AppKit
import Foundation
import MarklightCore
import Testing
@testable import MarklightApp

/// Typing with and without the preview, at growing file sizes. Not part of the
/// normal run, as timings mean nothing in a debug build:
///
///     MARKLIGHT_TIMING=1 swift test --package-path App -c release -Xswiftc -enable-testing --filter PreviewTimingTests
private let timingEnabled = ProcessInfo.processInfo.environment["MARKLIGHT_TIMING"] != nil

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

private func document(bytes: Int) -> String {
    String(repeating: section, count: max(1, bytes / section.utf8.count))
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

@MainActor @Suite("Preview timing", .serialized, .enabled(if: timingEnabled))
struct PreviewTimingTests {
    private struct Run {
        var firstRender = 0.0, keyMedian = 0.0, keyP95 = 0.0, keyMax = 0.0, mainLate = 0.0, catchUp = 0.0
        var updates = 0
    }

    /// 180 keys at 60 a second, in the middle of the file.
    private func run(text: String, layout: PaneLayout) async throws -> Run {
        var result = Run()
        let start = Date()
        let h = try PreviewHarness(text: text, layout: layout, size: NSSize(width: 1200, height: 800))
        defer { h.close() }
        if layout != .source {
            try await h.settle(timeout: 60)
            result.firstRender = Date().timeIntervalSince(start) * 1000
            let present = h.pane.updater.present
            h.pane.updater.present = { update, done in
                result.updates += 1
                present(update, done)
            }
        }
        await pump(for: 0.5) // let the first highlight finish
        h.textView.setSelectedRange(NSRange(location: text.utf16.count / 2, length: 0))

        var keys: [Double] = []
        var late = 0.0
        var next = Date()
        for i in 0..<180 {
            await pump(until: { Date() >= next }, timeout: 1)
            late = max(late, Date().timeIntervalSince(next) * 1000)
            let before = Date()
            h.textView.insertText(i % 6 == 5 ? " " : "x", replacementRange: h.textView.selectedRange())
            keys.append(Date().timeIntervalSince(before) * 1000)
            next = next.addingTimeInterval(1.0 / 60)
        }
        let lastKey = Date()
        if layout != .source {
            try await h.settle(timeout: 60)
            result.catchUp = Date().timeIntervalSince(lastKey) * 1000
        }
        result.keyMedian = percentile(keys, 0.5)
        result.keyP95 = percentile(keys, 0.95)
        result.keyMax = keys.max() ?? 0
        result.mainLate = late
        return result
    }

    /// Time each native key from beforeinput until the changed paragraph's text
    /// is present in the DOM. Coalesced messages retire several samples together.
    private func renderedBurst(bytes: Int, count: Int = 180, controlDelayMS: Int = 0) async throws -> (p95: Double, nativeP95: Double, patchP95: Double, late: Double) {
        let text = document(bytes: bytes), source = text as NSString
        let paragraph = source.range(of: "A paragraph", options: [], range: NSRange(location: source.length / 2,
                                                                                     length: source.length - source.length / 2))
        try #require(paragraph.location != NSNotFound)
        let at = paragraph.location + 5
        let h = try PreviewHarness(text: text, size: NSSize(width: 1200, height: 800), windowClass: RenderedKeyWindow.self)
        defer { h.close() }
        try await h.settle(timeout: 60)
        h.window.makeFirstResponder(h.webView)
        _ = try await h.js("""
        const root = document.querySelector('#doc');
        root.focus();
        marklight.select(at, at);
        const p = getSelection().anchorNode.parentElement.closest('p');
        p.scrollIntoView({block:'center'});
        const initial = p.textContent.length;
        let seen = 0;
        const events = [], samples = [], completed = [], costs = [];
        window.keyTiming = {samples, completed, costs};
        root.addEventListener('beforeinput', e => {
            if (e.inputType === 'insertText') events.push(performance.now());
        }, true);
        const patch = marklight.patch;
        marklight.patch = m => {
            const start = performance.now();
            if (delay) {
                const end = performance.now() + delay;
                while (performance.now() < end) {}
            }
            patch(m);
            const delivered = p.textContent.length - initial;
            const end = performance.now();
            costs.push(end - start);
            while (seen < delivered && seen < events.length) {
                samples.push(end - events[seen++]);
                completed.push(performance.timeOrigin + end);
            }
        };
        """, ["at": at, "delay": controlDelayMS])
        await pump(for: 0.5)
        let letters = ["a", "s", "d", "f"]
        let stream = (0..<count).map { letters[($0 * 7 + $0 / 5) % letters.count] }
        var expected = Array(text.utf16)
        expected.insert(contentsOf: stream.joined().utf16, at: at)
        var next = ProcessInfo.processInfo.systemUptime, maxLate = 0.0
        var sent: [Double] = []
        for letter in stream {
            _ = await pump(until: { ProcessInfo.processInfo.systemUptime >= next })
            maxLate = max(maxLate, (ProcessInfo.processInfo.systemUptime - next) * 1000)
            sent.append(Date().timeIntervalSince1970 * 1000)
            key(h, letter, code: UInt16(letters.firstIndex(of: letter)!))
            next += 1.0 / 60
        }
        try #require(await pump(until: { h.doc.buffer.units.count == expected.count }, timeout: 20), "typed keys missing at \(bytes) bytes")
        try await h.settle()
        #expect(h.doc.buffer.units == expected)
        #expect(Array(h.textView.string.utf16) == expected)
        let timing: [String: [Double]] = try await h.json("return window.keyTiming")
        let samples = try #require(timing["samples"]), completed = try #require(timing["completed"])
        let costs = try #require(timing["costs"])
        try #require(samples.count == count && completed.count == count && !costs.isEmpty)
        let fromNativeKey = zip(completed, sent).map { $0 - $1 }
        return (percentile(samples, 0.95), percentile(fromNativeKey, 0.95), percentile(costs, 0.95), maxLate)
    }

    @Test("Rendered keys arrive in order at 60 per second")
    func renderedTyping() async throws {
        for bytes in [4_000, 30_000, 100_000, 850_000] {
            let r = try await renderedBurst(bytes: bytes)
            print(String(format: "Rendered %d KB, 180 keys: p95 %.2f ms, native key to DOM p95 %.2f ms, JS patch p95 %.2f ms, main late max %.2f ms",
                         bytes / 1000, r.p95, r.nativeP95, r.patchP95, r.late))
            let limits: [Int: Double] = [100_000: 20, 850_000: 50]
            if let limit = limits[bytes] {
                #expect(r.p95 < limit, "beforeinput to DOM at \(bytes) bytes")
                // WebKit can queue native keys before the page sees beforeinput.
                #expect(r.nativeP95 < limit, "native dispatch to DOM at \(bytes) bytes")
            }
        }
        let slow = try await renderedBurst(bytes: 4_000, count: 16, controlDelayMS: 65)
        print(String(format: "Delayed-patch control p95 %.2f ms", slow.p95))
        #expect(slow.p95 >= 60)
    }

    @Test("Typing stays smooth with the preview open")
    func typing() async throws {
        print("| Size | Layout | First render | Key median | Key p95 | Key max | Main late (max) | Updates for 180 keys | Caught up after |")
        print("|---|---|---|---|---|---|---|---|---|")
        for (label, bytes) in [("4 KB", 4_000), ("30 KB", 30_000), ("100 KB", 100_000), ("850 KB", 850_000)] {
            let text = document(bytes: bytes)
            for layout in [PaneLayout.source, .split] {
                let r = try await run(text: text, layout: layout)
                func ms(_ v: Double) -> String { String(format: "%.1f ms", v) }
                print("| \(label) | \(layout) | \(layout == .source ? "" : ms(r.firstRender)) | \(ms(r.keyMedian)) | \(ms(r.keyP95)) | \(ms(r.keyMax)) | \(ms(r.mainLate)) | \(layout == .source ? "" : String(r.updates)) | \(layout == .source ? "" : ms(r.catchUp)) |")
            }
        }
    }
}
