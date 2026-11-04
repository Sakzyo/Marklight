import AppKit
import EditCore
import EditScenarios
import WebKit

// spike5-host: two real panes (WKWebView and NSTextView) sharing one buffer.
//
//   spike5-host                  everything
//   spike5-host --ime            IME and undo tests only
//   spike5-host --interactive    a real window for testing with a real IME

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

let sample = """
# 中文与日本語の試験

普通的段落，用来测试输入法。Some *emphasis*, **strong text**, and `inline code`.

- 列表项一
- [ ] 任务项
- item three

> 引用的段落

| 列 | Column |
|---|---|
| 值 | text |

```swift
let x = 1
```

The last paragraph.

"""

@MainActor func interactive(_ host: Host) async {
    host.window.makeFirstResponder(host.webView)
    await host.load(sample, selection: nil)
    print("Ready. Text below is the buffer after each change; lines starting >> are composition events.\n")
    host.bufferChanged = { print("buffer: \($0.debugDescription)") }
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        Task { @MainActor in
            let lines: [String] = await host.js("return marklight.trace()") ?? []
            for line in lines { print(">> \(line)") }
        }
    }
}

func editMenu() -> NSMenu {
    let main = NSMenu()
    let app = NSMenuItem()
    main.addItem(app)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    app.submenu = appMenu
    let edit = NSMenuItem()
    main.addItem(edit)
    // No Undo item: Cmd-Z goes to the buffer, through each pane.
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.submenu = editMenu
    return main
}

@MainActor func start() async {
    let args = CommandLine.arguments
    let only = args.firstIndex(of: "--only").map { args[$0 + 1] }
    let purify = try! String(contentsOf: Bundle.module.url(forResource: "purify.min", withExtension: "js", subdirectory: "Resources")!, encoding: .utf8)
    let bridge = try! String(contentsOf: Bundle.module.url(forResource: "bridge", withExtension: "js", subdirectory: "Resources")!, encoding: .utf8)
    let host = Host()
    let live = args.contains("--interactive")
    host.setUp(script: purify + "\n" + bridge, interactive: live)
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        host.ready = { c.resume() }
        host.webView.load(URLRequest(url: pageURL))
    }
    if live {
        NSApplication.shared.mainMenu = editMenu()
        await interactive(host)
        if args.contains("--smoke") {
            let text: String? = await host.js("return marklight.text().slice(0, 20)")
            print("smoke: \(text ?? "nil"), \(host.window.isVisible)")
            exit(0)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        host.window.makeKeyAndOrderFront(nil)
        keepAlive = host
        return
    }
    if args.contains("--ime") {
        _ = await imeTests(host)
        await undoTests(host)
        exit(0)
    }
    if !args.contains("--stability") { await regression(host, only: only) }
    if only == nil {
        await stability(host)
        _ = await imeTests(host)
        await undoTests(host)
    }
    exit(0)
}

var keepAlive: Host?

NSApplication.shared.setActivationPolicy(CommandLine.arguments.contains("--interactive") ? .regular : .prohibited)
Task { @MainActor in await start() }
NSApplication.shared.run()
