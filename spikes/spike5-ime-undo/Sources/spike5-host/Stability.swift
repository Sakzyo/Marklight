import AppKit
import EditCore
import Foundation

/// A deterministic document of about `blocks` top-level blocks.
func makeDoc(blocks: Int) -> String {
    var out = ""
    for i in 0..<blocks {
        switch i % 7 {
        case 0: out += "## Section \(i)\n\n"
        case 1: out += "Paragraph \(i) with *emphasis*, **strong text**, `inline code`, and a [link](https://e.com/\(i)). Filler text so it wraps across a line or two in the preview pane, like real prose does.\n\n"
        case 2: out += "- first item \(i)\n- second **item**\n  - nested\n- third item\n\n"
        case 3: out += "> Quoted paragraph \(i) with *emphasis*.\n\n"
        case 4: out += "```swift\nlet value\(i) = \(i)\nprint(value\(i))\n```\n\n"
        case 5: out += "| a | b |\n|---|---|\n| \(i) | *x* |\n\n"
        default: out += "Plain paragraph \(i) in 中文 with 🎉 emoji and more words after it to fill the line out.\n\n"
        }
    }
    return out
}

func percentile(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s[min(s.count - 1, Int(Double(s.count) * p))]
}

@MainActor final class Results {
    var rows: [(String, Bool, String)] = []
    func add(_ name: String, _ ok: Bool, _ detail: String = "") {
        rows.append((name, ok, detail))
        print("\(ok ? "pass" : "FAIL")  \(name)  \(detail)")
    }
}

@MainActor func offset(_ host: Host, block i: Int, plus k: Int) -> Int {
    host.editor.doc.root.children[i].range.lowerBound + k
}

/// Top-level paragraphs, which are safe places to put a caret or an edit.
@MainActor func paragraphs(_ host: Host) -> [Int] {
    host.editor.doc.root.children.enumerated().compactMap { $0.element.kind == .paragraph ? $0.offset : nil }
}

@MainActor func remote(_ host: Host, at: Int, delete: Int = 0, insert: String) async {
    // Through the real source pane's text storage, as an edit there would arrive.
    host.textView.textStorage?.replaceCharacters(in: NSRange(location: at, length: delete), with: insert)
}

@MainActor func stats(_ host: Host) async -> [String: Any] {
    (await host.js("return marklight.stats()") as [String: Any]?) ?? [:]
}

func number(_ s: [String: Any], _ k: String) -> Int { (s[k] as? NSNumber)?.intValue ?? 0 }
func list(_ s: [String: Any], _ k: String) -> [Double] { (s[k] as? [NSNumber])?.map { $0.doubleValue } ?? [] }

@MainActor func stability(_ host: Host) async {
    let results = Results()
    let doc = makeDoc(blocks: 210)
    print("\ndocument: \(doc.utf8.count / 1024) KB, 210 blocks")

    // Node identity
    await host.load(doc, selection: nil)
    let _: Bool? = await host.js("marklight.watch(); return true")
    var ps = paragraphs(host)
    let mid = ps[ps.count / 2]
    let caret: Int = await host.js("return marklight.selectBlock(i, 5)", ["i": mid]) ?? 0
    let _: Int? = await host.js("return marklight.tagAll()")
    _ = await stats(host)
    host.window.makeFirstResponder(host.webView)
    host.key("x", code: 0)
    await host.settle()
    var s = await stats(host)
    let local: [Int] = await host.js("return marklight.untagged(i)", ["i": mid]) ?? []
    results.add("typing: no node outside the block is replaced", local.first == 0, "\(local.first ?? -1) of \(local.last ?? -1) lost; nodes added \(number(s, "added")), removed \(number(s, "removed")), text \(number(s, "text")), attrs \(number(s, "attrs"))")
    results.add("typing: edit landed at the caret", host.editor.units[caret] == 0x78)

    // Source pane edits a different block
    let _: Int? = await host.js("return marklight.tagAll()")
    _ = await stats(host)
    let runBefore: Int = await host.js("return marklight.runTag()") ?? -1
    let offsetBefore: Int = await host.js("return marklight.caretOffset()") ?? -1
    let selBefore: [Int] = await host.js("return marklight.selection()") ?? []
    let later = ps[ps.count * 3 / 4]
    await remote(host, at: offset(host, block: later, plus: 3), insert: "LATER")
    await host.settle()
    s = await stats(host)
    var runAfter: Int = await host.js("return marklight.runTag()") ?? -2
    var offsetAfter: Int = await host.js("return marklight.caretOffset()") ?? -2
    var selAfter: [Int] = await host.js("return marklight.selection()") ?? []
    var lost: [Int] = await host.js("return marklight.untagged(i)", ["i": later]) ?? []
    results.add("remote edit below: caret node and offset untouched", runBefore == runAfter && offsetBefore == offsetAfter && selBefore == selAfter, "\(selBefore) to \(selAfter)")
    results.add("remote edit below: other nodes untouched", lost.first == 0, "\(lost.first ?? -1) of \(lost.last ?? -1) lost; added \(number(s, "added")), removed \(number(s, "removed")), text \(number(s, "text"))")

    let earlier = ps[ps.count / 4]
    await remote(host, at: offset(host, block: earlier, plus: 3), insert: "EARLIER")
    await host.settle()
    runAfter = await host.js("return marklight.runTag()") ?? -2
    offsetAfter = await host.js("return marklight.caretOffset()") ?? -2
    selAfter = await host.js("return marklight.selection()") ?? []
    lost = await host.js("return marklight.untagged(i)", ["i": earlier]) ?? []
    results.add("remote edit above: caret node and offset untouched", runBefore == runAfter && offsetBefore == offsetAfter, "node \(runBefore)=\(runAfter), offset \(offsetBefore)=\(offsetAfter)")
    results.add("remote edit above: selection maps to the shifted source", selAfter.first == (selBefore.first ?? 0) + 7, "\(selBefore) to \(selAfter)")
    results.add("remote edit above: other nodes untouched", lost.first == 0, "\(lost.first ?? -1) lost")
    host.key("Y", code: 0)
    await host.settle()
    results.add("type after remote edits: lands at the caret", host.editor.units[selAfter.first ?? 0] == 0x59)
    var bad = await host.verifyDOM()
    results.add("DOM equals a fresh render", bad == nil, bad ?? "")

    // Source pane edits the focused block
    await host.load("one two three four\n\nnext\n", selection: 8..<8)
    await remote(host, at: 0, insert: "AB")
    await host.settle()
    var sel: [Int] = await host.js("return marklight.selection()") ?? []
    results.add("remote edit in the same block, before the caret: caret follows", sel == [10, 10], "\(sel)")
    await remote(host, at: 15, insert: "ZZ")
    await host.settle()
    sel = await host.js("return marklight.selection()") ?? []
    results.add("remote edit in the same block, after the caret: caret stays", sel == [10, 10], "\(sel)")
    await remote(host, at: 8, delete: 6, insert: "")
    await host.settle()
    sel = await host.js("return marklight.selection()") ?? []
    results.add("remote delete around the caret: caret collapses to the edit", sel == [8, 8], "\(sel)")
    await remote(host, at: 0, delete: host.editor.units.count, insert: "fresh\n")
    await host.settle()
    sel = await host.js("return marklight.selection()") ?? []
    results.add("remote replaces the whole document: caret stays valid", sel.count == 2 && sel[0] <= 6, "\(sel)")
    bad = await host.verifyDOM()
    results.add("DOM equals a fresh render after remote edits", bad == nil, bad ?? "")

    // Scroll
    await host.load(doc, selection: nil)
    ps = paragraphs(host)
    let _: Bool? = await host.js("marklight.scrollTo(4000); return true")
    try? await Task.sleep(nanoseconds: 100_000_000)
    func anchorCheck(_ name: String, _ edit: () async -> Void) async {
        let top: Double = (await host.js("return marklight.watchVisible()") as NSNumber?)?.doubleValue ?? 0
        await edit()
        await host.settle()
        let now: Double = (await host.js("return marklight.watchedTop()") as NSNumber?)?.doubleValue ?? 1e9
        results.add(name, abs(now - top) <= 1, String(format: "visible block moved %.1f px", now - top))
    }
    await anchorCheck("scroll: paragraphs inserted far above") {
        await remote(host, at: offset(host, block: 1, plus: 0), insert: String(repeating: "New paragraph above the viewport.\n\n", count: 8))
    }
    await anchorCheck("scroll: paragraphs removed far above") {
        await remote(host, at: offset(host, block: 1, plus: 0), delete: 35 * 8, insert: "")
    }
    await anchorCheck("scroll: block above grows") {
        await remote(host, at: offset(host, block: 1, plus: 0), insert: String(repeating: "long text ", count: 200))
    }
    await anchorCheck("scroll: edit below the viewport") {
        await remote(host, at: offset(host, block: 200, plus: 0), insert: "Below\n\n")
    }

    // 60 keystrokes per second
    func burst(_ name: String, blocks: Int) async {
        let text = makeDoc(blocks: blocks)
        await host.load(text, selection: nil)
        let ps = paragraphs(host)
        let at: Int = await host.js("return marklight.selectBlock(i, 5)", ["i": ps[ps.count / 2]]) ?? 0
        let _: Int? = await host.js("return marklight.tagAll()")
        _ = await stats(host)
        let phrase = Array("the quick brown fox jumps over the lazy dog ".utf16)
        let count = 180
        let expected = host.editor.units.count + count
        host.window.makeFirstResponder(host.webView)
        let startKeys = host.messages
        let t0 = Date()
        var lateness: [Double] = []
        for i in 0..<count {
            let due = t0.addingTimeInterval(Double(i) / 60)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            lateness.append(max(0, -due.timeIntervalSinceNow) * 1000)
            host.key(String(decoding: [phrase[i % phrase.count]], as: UTF16.self), code: 0)
        }
        let sendTime = Date().timeIntervalSince(t0)
        while host.textView.string.utf16.count < expected, Date().timeIntervalSince(t0) < 60 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let allIn = Date().timeIntervalSince(t0)
        await host.settle()
        let s = await stats(host)
        let typed = (0..<count).map { phrase[$0 % phrase.count] }
        let got = Array(host.editor.units[at..<(at + count)])
        let lost: [Int] = await host.js("return marklight.untagged(i)", ["i": ps[ps.count / 2]]) ?? []
        let bad = await host.verifyDOM()
        let sourceOK = host.textView.string.utf8.elementsEqual(host.editor.text.utf8)
        let latency = list(s, "latency")
        let patchMs = list(s, "patchMs")
        results.add("\(name): every key arrives in order", got == typed, String(format: "sent in %.2f s, all in buffer at %.2f s, %d messages, %d patches", sendTime, allIn, host.messages - startKeys, number(s, "patches")))
        results.add("\(name): no flicker (no block replaced)", number(s, "replaced") == 0 && lost.first == 0, "blocks replaced \(number(s, "replaced")), nodes added \(number(s, "added")), removed \(number(s, "removed")), lost \(lost.first ?? -1)")
        results.add("\(name): DOM and source pane agree", bad == nil && sourceOK, bad ?? "")
        print(String(format: "      page key to DOM: median %.1f ms, p95 %.1f ms, max %.1f ms; DOM patch median %.2f ms, max %.2f ms; main thread late by median %.1f ms, max %.1f ms", percentile(latency, 0.5), percentile(latency, 0.95), latency.max() ?? 0, percentile(patchMs, 0.5), patchMs.max() ?? 0, percentile(lateness, 0.5), lateness.max() ?? 0))
    }
    await burst("60 keys/s, 3 KB", blocks: 30)
    await burst("60 keys/s, 30 KB", blocks: 340)
    await burst("60 keys/s, 100 KB", blocks: 1130)

    // Source pane typing at 60 keys/s with the caret in the preview
    await host.load(doc, selection: nil)
    ps = paragraphs(host)
    let _: Int? = await host.js("return marklight.selectBlock(i, 5)", ["i": ps[ps.count / 2]])
    let _: Int? = await host.js("return marklight.tagAll()")
    _ = await stats(host)
    let selStart: [Int] = await host.js("return marklight.selection()") ?? []
    let target = offset(host, block: ps[3], plus: 0)
    host.textView.setSelectedRange(NSRange(location: target, length: 0))
    host.window.makeFirstResponder(host.textView)
    let edits0 = host.sourceEdits, renders0 = host.renderedRenders, mirrors0 = host.sourceMirrors
    let t0 = Date()
    for i in 0..<180 {
        host.key("s", code: 0)
        let wait = t0.addingTimeInterval(Double(i + 1) / 60).timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }
    await host.settle()
    s = await stats(host)
    host.window.makeFirstResponder(host.webView)
    let _: Bool? = await host.js("marklight.focusRoot(); return true")
    try? await Task.sleep(nanoseconds: 50_000_000)
    let restored: [Int] = await host.js("return marklight.selection()") ?? []
    bad = await host.verifyDOM()
    results.add("source pane at 60 keys/s: every edit reaches the buffer", host.sourceEdits - edits0 == 180, "\(host.sourceEdits - edits0) edits, \(host.renderedRenders - renders0) renders, \(number(s, "patches")) patches")
    results.add("source pane at 60 keys/s: no echo back to the source pane", host.sourceMirrors == mirrors0, "\(host.sourceMirrors - mirrors0) mirrors")
    results.add("source pane at 60 keys/s: preview caret comes back in the same text", restored == selStart.map { $0 + 180 }, "\(selStart) to \(restored)")
    results.add("source pane at 60 keys/s: DOM agrees", bad == nil, bad ?? "")

    // The reverse: preview edits while the source pane holds a caret and scroll
    await host.load(doc, selection: nil)
    ps = paragraphs(host)
    host.textView.layoutManager?.ensureLayout(for: host.textView.textContainer!)
    host.textView.textLayoutManager?.ensureLayout(for: host.textView.textLayoutManager!.documentRange)
    let sourceCaret = offset(host, block: ps[ps.count * 3 / 4], plus: 4)
    host.textView.setSelectedRange(NSRange(location: sourceCaret, length: 0))
    host.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 3000))
    host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
    let originBefore = host.scrollView.contentView.bounds.origin
    let _: Int? = await host.js("return marklight.selectBlock(i, 5)", ["i": ps[ps.count / 4]])
    host.window.makeFirstResponder(host.webView)
    for _ in 0..<30 {
        host.key("r", code: 0)
        try? await Task.sleep(nanoseconds: 16_000_000)
    }
    await host.settle()
    let sourceSel = host.textView.selectedRange().location
    let originAfter = host.scrollView.contentView.bounds.origin
    results.add("preview edits above: source caret follows its text", sourceSel == sourceCaret + 30, "\(sourceCaret) to \(sourceSel)")
    results.add("preview edits: source scroll doesn't jump", abs(originAfter.y - originBefore.y) < 1, "y \(originBefore.y) to \(originAfter.y)")
    results.add("preview edits: source text agrees", host.textView.string.utf8.elementsEqual(host.editor.text.utf8))

    // Both at once
    await host.load(doc, selection: nil)
    ps = paragraphs(host)
    let typedAt: Int = await host.js("return marklight.selectBlock(i, 5)", ["i": ps[ps.count / 2]]) ?? 0
    host.window.makeFirstResponder(host.webView)
    let remoteAt = offset(host, block: ps[2], plus: 0)
    for i in 0..<120 {
        host.key("k", code: 0)
        if i % 2 == 0 { await remote(host, at: remoteAt, insert: "R") }
        try? await Task.sleep(nanoseconds: 16_000_000)
    }
    await host.settle()
    let shifted = typedAt + 60
    let ks = host.editor.units[shifted..<(shifted + 120)].allSatisfy { $0 == 0x6B }
    let rs = host.editor.units[remoteAt..<(remoteAt + 60)].allSatisfy { $0 == 0x52 }
    bad = await host.verifyDOM()
    results.add("both panes at once: both streams land intact", ks && rs, "typed run at expected offset \(ks), remote run \(rs)")
    results.add("both panes at once: DOM and source agree", bad == nil && host.textView.string.utf8.elementsEqual(host.editor.text.utf8), bad ?? "")

    // Keys that land while an edit is still in flight
    func race(_ name: String, _ steps: [(String, UInt16)], expect: String) async {
        let text = makeDoc(blocks: 1130)
        await host.load(text, selection: nil)
        let ps = paragraphs(host)
        let i = ps[ps.count / 2]
        let at: Int = await host.js("return marklight.selectBlock(i, 2)", ["i": i]) ?? 0
        let original = Array(host.editor.units[at..<(at + 6)])
        host.window.makeFirstResponder(host.webView)
        for (chars, code) in steps {
            host.key(chars, code: code)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        await host.settle()
        let changed = steps.filter { $0.1 == 0 }.count
        let got = String(decoding: host.editor.units[at..<(at + 6 + changed)], as: UTF16.self)
        let wanted = String(decoding: Array(expect.utf16) + original, as: UTF16.self)
        let _ = wanted
        results.add(name, got.hasPrefix(expect), "got \(got.debugDescription), start of text \(String(decoding: original, as: UTF16.self).debugDescription)")
    }
    let leftKey = ("\u{F702}", UInt16(123)), rightKey = ("\u{F703}", UInt16(124))
    await race("type, left, type on a slow document", [("x", 0), leftKey, ("y", 0)], expect: "yx")
    await race("type, left, left, right, type on a slow document", [("x", 0), leftKey, leftKey, rightKey, ("y", 0)], expect: "yx")

    // Structural edits on a long list
    var longList = ""
    for i in 0..<500 { longList += "- item \(i) with **bold** text\n" }
    await host.load(longList + "\nafter\n", selection: nil)
    let _: Int? = await host.js("return marklight.selectBlock(i, 40)", ["i": 0])
    _ = await stats(host)
    host.window.makeFirstResponder(host.webView)
    host.key("\r", code: 36)
    await host.settle()
    s = await stats(host)
    bad = await host.verifyDOM()
    results.add("Enter in a 500-item list", bad == nil, "nodes added \(number(s, "added")), removed \(number(s, "removed")), text \(number(s, "text")), attrs \(number(s, "attrs")), patch \(String(format: "%.1f", list(s, "patchMs").first ?? 0)) ms")

    let failures = results.rows.filter { !$0.1 }.count
    print("\nstability: \(results.rows.count - failures) passed, \(failures) failed")
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

extension Host {
    /// Finds a block again by its text after an edit moved it in the list.
    func renderedIndex(of text: String?, near index: Int) -> Int {
        guard let text else { return index }
        let children = editor.doc.root.children
        let wanted = text.prefix(10)
        var best = index, bestDistance = Int.max
        for (i, b) in children.enumerated() {
            let s = String(decoding: editor.units[b.range], as: UTF16.self)
            let plain = s.replacingOccurrences(of: "```swift\n", with: "").replacingOccurrences(of: "## ", with: "")
                .replacingOccurrences(of: "> ", with: "").replacingOccurrences(of: "- ", with: "")
            if plain.hasPrefix(wanted), abs(i - index) < bestDistance {
                best = i
                bestDistance = abs(i - index)
            }
        }
        return best
    }
}
