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
