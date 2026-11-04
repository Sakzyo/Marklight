import AppKit
import EditCore
import EditScenarios
import WebKit

// spike4-host: two real panes (WKWebView and NSTextView) sharing one buffer.
//
//   spike4-host                  scenarios, then stability tests
//   spike4-host --stability      stability tests only
//   spike4-host --only <text>    scenarios whose name contains <text>

@MainActor func regression(_ host: Host, only: String?) async {
    var passed = 0, failed: [String] = []
    var mirrorBad = 0, domBad: [String] = []
    func check(_ name: String, _ expected: String, _ expectedCaret: Range<Int>) async {
        let caret: [Int] = await host.js("return marklight.selection()") ?? []
        let visual = host.visualCaret(expectedCaret.lowerBound)
        let caretOK = caret == [expectedCaret.lowerBound, expectedCaret.upperBound] || caret == [visual, visual]
        if !host.textView.string.utf8.elementsEqual(host.editor.text.utf8) { mirrorBad += 1 }
        if let bad = await host.verifyDOM() { domBad.append("\(name): \(bad)") }
        if host.editor.text.utf8.elementsEqual(expected.utf8), caretOK {
            passed += 1
        } else {
            failed.append("\(name)\n     got  \(host.editor.text.debugDescription) caret \(caret)\n     want \(expected.debugDescription) caret \(expectedCaret)")
        }
    }
    for s in allScenarios where only.map({ s.name.contains($0) }) ?? true {
        let (text, selection) = parseMarkers(s.before)
        let (expected, expectedCaret) = parseMarkers(s.after)
        await host.load(text, selection: selection)
        await host.settle()
        for action in s.actions { await host.perform(action) }
        await check(s.name, expected, expectedCaret)
    }
    for t in realInput where only.map({ t.name.contains($0) }) ?? true {
        let (text, selection) = parseMarkers(t.before)
        let (expected, expectedCaret) = parseMarkers(t.after)
        await host.load(text, selection: selection)
        await host.settle()
        for step in t.steps {
            switch step {
            case .key(let chars, let code, let flags):
                host.key(chars, code: code, flags: flags)
            case .click(let offset):
                if let at: [NSNumber] = await host.js("return marklight.rectAt(o)", ["o": offset]) {
                    host.click(x: at[0].doubleValue, y: at[1].doubleValue)
                }
            case .selectAll:
                let _: Bool? = await host.js("marklight.selectAll(); return true")
            }
            await host.settle()
        }
        await check(t.name, expected, expectedCaret)
    }
    print("regression through the patcher: \(passed) passed, \(failed.count) failed")
    print("source pane out of step: \(mirrorBad), DOM differs from a fresh render: \(domBad.count)")
    for f in failed { print("FAIL \(f)") }
    for d in domBad.prefix(8) { print("DOM \(d.prefix(300))") }
}

@MainActor func start() async {
    let args = CommandLine.arguments
    let only = args.firstIndex(of: "--only").map { args[$0 + 1] }
    let purify = try! String(contentsOf: Bundle.module.url(forResource: "purify.min", withExtension: "js", subdirectory: "Resources")!, encoding: .utf8)
    let bridge = try! String(contentsOf: Bundle.module.url(forResource: "bridge", withExtension: "js", subdirectory: "Resources")!, encoding: .utf8)
    let host = Host()
    host.setUp(script: purify + "\n" + bridge)
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        host.ready = { c.resume() }
        host.webView.load(URLRequest(url: pageURL))
    }
    if !args.contains("--stability") { await regression(host, only: only) }
    if only == nil { await stability(host) }
}

NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    await start()
    exit(0)
}
NSApplication.shared.run()
