import AppKit
import Foundation
import MarklightCore
import Testing
@testable import MarklightApp

/// Records every CSP violation from here on, then tries to load a remote image.
private let tryRemoteImage = """
window._violations = [];
document.addEventListener('securitypolicyviolation', e => window._violations.push(e.effectiveDirective + ' ' + e.blockedURI));
const img = document.createElement('img');
img.src = 'https://example.invalid/pixel.png';
document.getElementById('doc').append(img);
"""

extension PreviewSuites {
    @MainActor @Suite("Layouts and remote images")
    struct PreviewLayoutTests {
        // MARK: - Layouts

        @Test("First launch is split")
        func firstLaunch() {
            PaneLayout.forget()
            #expect(PaneLayout.remembered == .split)
        }

        @Test("Each layout shows the right panes")
        func layouts() async throws {
            let h = try PreviewHarness(text: "# Title\n")
            defer { h.close() }
            try await h.settle()
            let source = h.controller.editor.scrollView

            #expect(!source.isHidden && source.frame.width > 100)
            #expect(!h.pane.view.superview!.isHidden && h.pane.view.superview!.frame.width > 100)

            h.controller.setLayout(.source)
            await pump(for: 0.05)
            #expect(!source.isHidden)
            #expect(h.pane.view.superview!.isHidden)

            h.controller.setLayout(.preview)
            await pump(for: 0.05)
            #expect(source.isHidden)
            #expect(!h.pane.view.superview!.isHidden)
            #expect(h.webView.frame.width > 400)

            h.controller.setLayout(.split)
            await pump(for: 0.05)
            #expect(!source.isHidden && source.frame.width > 100, "\(source.frame)")
            #expect(h.webView.frame.width > 100, "\(h.webView.frame)")
        }

        @Test("A moved divider comes back after hiding a pane")
        func divider() async throws {
            let h = try PreviewHarness(text: "# Title\n")
            defer { h.close() }
            let split = try #require(h.controller.editor.scrollView.superview as? NSSplitView)
            split.setPosition(300, ofDividerAt: 0)
            await pump(for: 0.05)
            h.controller.setLayout(.preview)
            await pump(for: 0.05)
            h.controller.setLayout(.split)
            await pump(for: 0.05)
            #expect(abs(h.controller.editor.scrollView.frame.width - 300) < 2, "\(h.controller.editor.scrollView.frame)")
        }

        @Test("The choice is remembered, and a new window uses it")
        func remembered() throws {
            let first = try PreviewHarness(text: "a\n")
            defer { first.close() }
            first.controller.setLayout(.preview)
            #expect(PaneLayout.remembered == .preview)
            let second = EditorWindowController(document: first.doc)
            #expect(second.layout == .preview)
        }

        @Test("A source-only window never makes a web view")
        func sourceOnly() throws {
            let h = try PreviewHarness(text: "a\n", layout: .source)
            defer { h.close() }
            #expect(h.controller.preview == nil)
        }

        @Test("A hidden preview does no work, and catches up when it's shown")
        func hiddenPreview() async throws {
            let h = try PreviewHarness(text: "one\n")
            defer { h.close() }
            try await h.settle()
            let shown = h.pane.updater.shownVersion
            h.controller.setLayout(.source)
            try h.doc.buffer.apply(Patch(range: 0..<0, replacement: Array("new ".utf16), origin: .command))
            await pump(for: 0.2)
            #expect(h.pane.updater.shownVersion == shown)
            h.controller.setLayout(.split)
            try await h.settle()
            let text = try await h.js("return document.querySelector('p').textContent") as? String
            #expect(text == "new one")
        }

        @Test("The View menu has the three layouts, with shortcuts, and marks the current one")
        func viewMenu() throws {
            _ = NSApplication.shared
            let menu = try #require(MainMenu.make().items.compactMap(\.submenu).first { $0.title == "View" })
            #expect(menu.items.map(\.title) == ["Source", "Preview", "Split"])
            #expect(menu.items.map(\.keyEquivalent) == ["1", "2", "3"])
            #expect(menu.items.allSatisfy { $0.keyEquivalentModifierMask == .command })

            let h = try PreviewHarness(text: "a\n", layout: .preview)
            defer { h.close() }
            for item in menu.items { #expect(h.controller.validateMenuItem(item)) }
            #expect(menu.items.map(\.state) == [.off, .on, .off])
        }

        @Test("Cmd-Z works with the preview focused, on the one undo stack")
        func undoFromPreview() async throws {
            let h = try PreviewHarness(text: "text\n")
            defer { h.close() }
            try await h.settle()
            h.textView.setSelectedRange(NSRange(location: 4, length: 0))
            h.textView.insertText("!", replacementRange: h.textView.selectedRange())
            #expect(h.doc.buffer.text == "text!\n")
            #expect(h.webView.responds(to: #selector(PreviewWebView.undo(_:))))
            #expect(h.webView.validateUserInterfaceItem(menuItem(#selector(PreviewWebView.undo(_:)))))
            #expect(!h.webView.validateUserInterfaceItem(menuItem(#selector(PreviewWebView.redo(_:)))))
            h.webView.undo(nil)
            #expect(h.doc.buffer.text == "text\n")
            #expect(h.textView.string == "text\n")
            h.webView.redo(nil)
            #expect(h.doc.buffer.text == "text!\n")
        }

        private func menuItem(_ action: Selector) -> NSMenuItem {
            NSMenuItem(title: "", action: action, keyEquivalent: "")
        }

        // MARK: - Remote images

        @Test("The bar shows only when there are remote images to load")
        func bar() async throws {
            let plain = try PreviewHarness(text: "![a](a.png)\n")
            defer { plain.close() }
            try await plain.settle()
            #expect(plain.pane.bar.isHidden)

            let remote = try PreviewHarness(text: "![a](https://example.invalid/a.png)\n")
            defer { remote.close() }
            try await remote.settle()
            #expect(!remote.pane.bar.isHidden)
        }

        @Test("The bar follows edits")
        func barFollowsEdits() async throws {
            let h = try PreviewHarness(text: "text\n")
            defer { h.close() }
            try await h.settle()
            #expect(h.pane.bar.isHidden)
            try h.doc.buffer.apply(Patch(range: 0..<0, replacement: Array("![a](https://example.invalid/a.png)\n\n".utf16), origin: .command))
            try await h.settle()
            #expect(!h.pane.bar.isHidden)
        }

        @Test("Remote images are blocked until the bar is clicked, for that window only")
        func loadRemoteImages() async throws {
            let h = try PreviewHarness(text: "![a](https://example.invalid/a.png)\n")
            defer { h.close() }
            let other = try PreviewHarness(text: "![a](https://example.invalid/a.png)\n")
            defer { other.close() }
            try await h.settle()
            try await other.settle()

            func violations(_ h: PreviewHarness) async throws -> [String] {
                _ = try await h.js(tryRemoteImage)
                await pump(for: 0.2)
                return try await h.json("return window._violations")
            }
            #expect(try await violations(h).contains { $0.hasPrefix("img-src https://example.invalid") })

            let button = h.pane.bar.button
            #expect(button.sendAction(button.action, to: button.target))
            #expect(h.pane.remoteImagesAllowed)
            #expect(h.pane.bar.isHidden)
            await pump(for: 0.1)
            try await h.settle()
            #expect(try await violations(h).isEmpty, "the wider CSP should allow https images")

            #expect(!other.pane.remoteImagesAllowed)
            #expect(try await violations(other).contains { $0.hasPrefix("img-src https://example.invalid") })
        }

        @Test("Allowing remote images keeps http, and everything else, blocked")
        func onlyHTTPS() {
            let csp = PreviewScheme.csp(remoteImages: true)
            #expect(csp.contains("img-src marklight-preview: data: https:;"))
            #expect(!csp.contains("http:"))
            #expect(csp.contains("script-src 'none'"))
            #expect(csp.contains("connect-src 'none'"))
            #expect(!PreviewScheme.csp(remoteImages: false).contains("https:"))
        }

        @Test("Loading remote images keeps the scroll position")
        func loadKeepsScroll() async throws {
            let text = "![a](https://example.invalid/a.png)\n\n" + (0..<200).map { "Paragraph \($0).\n\n" }.joined()
            let h = try PreviewHarness(text: text, size: NSSize(width: 1000, height: 500))
            defer { h.close() }
            try await h.settle()
            _ = try await h.js("window.scrollTo(0, 2000)")
            h.pane.allowRemoteImages()
            await pump(for: 0.1)
            try await h.settle()
            await pump(for: 0.2) // the scroll is restored just after the load
            let y = try await h.js("return scrollY") as? Double
            #expect(y == 2000)
        }
    }
}
