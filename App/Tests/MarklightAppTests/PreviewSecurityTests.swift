import AppKit
import CryptoKit
import Foundation
import MarklightCore
import Testing
import WebKit
@testable import MarklightApp

private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

private let evilSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" onload="parent.document.title='pwned-svg-img-onload'">\
<script>parent.document.title='pwned-svg-img-script'</script><rect width="10" height="10" fill="red"/></svg>
"""

/// `secret/secret.png`, and `repo/` with `.git`, `assets/shared.png`, and `docs/`,
/// which is where the document lives.
private struct AttackTree {
    let top: URL
    let repo: URL
    var docs: URL { repo.appendingPathComponent("docs") }
    var document: URL { docs.appendingPathComponent("attack.md") }

    init(git: Bool = true) throws {
        let fm = FileManager.default
        top = try makeTemporaryFolder()
        repo = top.appendingPathComponent("repo")
        let docs = repo.appendingPathComponent("docs")
        for folder in ["secret", "repo/assets", "repo/docs/images/sub"] {
            try fm.createDirectory(at: top.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        if git { try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true) }
        for file in ["secret/secret.png", "repo/assets/shared.png", "repo/docs/images/ok.png",
                     "repo/docs/images/sub/nested.png", "repo/docs/images/with space.png"] {
            try onePixelPNG.write(to: top.appendingPathComponent(file))
        }
        try Data(evilSVG.utf8).write(to: docs.appendingPathComponent("images/evil.svg"))
        try Data("not an image".utf8).write(to: docs.appendingPathComponent("notes.txt"))
        try Data("# Other\n".utf8).write(to: docs.appendingPathComponent("other.md"))
        try fm.createSymbolicLink(atPath: docs.appendingPathComponent("link-in.png").path, withDestinationPath: "images/ok.png")
        try fm.createSymbolicLink(atPath: docs.appendingPathComponent("link-out.png").path, withDestinationPath: "../../secret/secret.png")
        try fm.copyItem(at: fixturesFolder.appendingPathComponent("attack.md"), to: docs.appendingPathComponent("attack.md"))
    }
}

private struct PageState: Decodable {
    let title: String
    let images: [[String: String]]
    let dangerousTags: [String]
    let handlers: [String]
    let scriptLinks: [String]
    let forgedOffsets: Int
    let forgedEditable: Int
}

private let stateScript = """
const doc = document.getElementById('doc');
const all = [...doc.querySelectorAll('*')];
return {
  title: document.title,
  images: [...doc.querySelectorAll('img')].map(i => ({ alt: i.getAttribute('alt') || '', src: i.getAttribute('src') || '',
                                                       loaded: String(i.complete && i.naturalWidth > 0) })),
  dangerousTags: all.map(e => e.tagName.toLowerCase())
    .filter(t => ['script', 'iframe', 'object', 'embed', 'form', 'meta', 'base', 'link', 'style', 'frame'].includes(t)),
  handlers: all.flatMap(e => [...e.attributes].filter(a => a.name.startsWith('on')).map(a => e.tagName + '[' + a.name + ']')),
  scriptLinks: [...doc.querySelectorAll('a')].filter(a => /^\\s*(javascript|data):/i.test(a.getAttribute('href') || '')).map(a => a.textContent),
  forgedOffsets: doc.querySelectorAll('[data-raw] [data-src], [data-raw] [data-run], [data-raw] [data-caret]').length,
  forgedEditable: doc.querySelectorAll('[contenteditable]').length,
};
"""

@MainActor private func state(_ h: PreviewHarness) async throws -> PageState {
    let raw: [String: Any] = try await h.json(stateScript)
    return try JSONDecoder().decode(PageState.self, from: JSONSerialization.data(withJSONObject: raw))
}

private let wanted = ["ok", "nested", "symlink inside tree", "space in name", "svg with script", "parent folder", "onload handler"]
private let unwanted = ["traversal", "deep traversal", "encoded traversal", "encoded slash traversal", "absolute path", "file url",
                        "symlink out of tree", "non-image in tree", "other host", "remote"]

private func url(_ string: String) -> URL { URL(string: string)! }

@MainActor @Suite("Preview security", .serialized)
struct PreviewSecurityTests {
    // MARK: - Path policy

    @Test("The access root is the repository, and the page sits at the document's path")
    func location() throws {
        let tree = try AttackTree()
        let location = PreviewLocation(documentURL: tree.document)
        #expect(location.root == tree.repo.path)
        #expect(location.pagePath == "/docs/attack.md")
        #expect(location.pageURL.absoluteString == "marklight-preview://doc/docs/attack.md")
        #expect(location.resource(for: location.pageURL) == .page)
    }

    @Test("Outside a repository, the access root is the document's folder")
    func noRepository() throws {
        let tree = try AttackTree(git: false)
        let location = PreviewLocation(documentURL: tree.document)
        #expect(location.root == tree.docs.path)
        #expect(location.pagePath == "/attack.md")
        guard case .image = location.resource(for: url("marklight-preview://doc/images/ok.png")) else {
            Issue.record("an image in the folder should load")
            return
        }
        guard case .denied = location.resource(for: url("marklight-preview://doc/../assets/shared.png")) else {
            Issue.record("the parent folder is out of bounds with no repository")
            return
        }
    }

    @Test("A `.git` file counts, as in a worktree or submodule")
    func gitFile() throws {
        let folder = try makeTemporaryFolder()
        try Data("gitdir: elsewhere\n".utf8).write(to: folder.appendingPathComponent(".git"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        let location = PreviewLocation(documentURL: folder.appendingPathComponent("a/b/doc.md"))
        #expect(location.root == folder.path)
    }

    @Test("Names that need escaping survive the round trip")
    func awkwardNames() throws {
        let folder = try makeTemporaryFolder()
        let location = PreviewLocation(documentURL: folder.appendingPathComponent("a b#c?d%e 漢.md"))
        #expect(location.pageURL.path == "/a b#c?d%e 漢.md")
        #expect(location.resource(for: location.pageURL) == .page)
    }

    @Test("An unsaved document reads nothing")
    func untitled() {
        let location = PreviewLocation(documentURL: nil)
        #expect(location.resource(for: location.pageURL) == .page)
        guard case .denied = location.resource(for: url("marklight-preview://doc/etc/hosts")) else {
            Issue.record("an unsaved document has no access root")
            return
        }
    }

    @Test("The path policy", arguments: [
        ("marklight-preview://doc/docs/images/ok.png", true),
        ("marklight-preview://doc/docs/images/sub/nested.png", true),
        ("marklight-preview://doc/docs/images/with%20space.png", true),
        ("marklight-preview://doc/docs/images/evil.svg", true),
        ("marklight-preview://doc/docs/link-in.png", true),
        ("marklight-preview://doc/assets/shared.png", true),
        ("marklight-preview://doc/docs/link-out.png", false),
        ("marklight-preview://doc/secret/secret.png", false),
        ("marklight-preview://doc/docs/%2e%2e/%2e%2e/secret/secret.png", false),
        ("marklight-preview://doc/docs/..%2f..%2fsecret%2fsecret.png", false),
        ("marklight-preview://doc/../secret/secret.png", false),
        ("marklight-preview://doc/etc/passwd", false),
        ("marklight-preview://doc/docs/notes.txt", false),
        ("marklight-preview://doc/docs/other.md", false),
        ("marklight-preview://doc/docs/images", false),
        ("marklight-preview://doc/docs/images/ok.png%00.txt", false),
        ("marklight-preview://elsewhere/docs/images/ok.png", false),
        ("file:///etc/hosts", false),
        ("https://example.com/a.png", false),
    ])
    func pathPolicy(link: String, allowed: Bool) throws {
        let tree = try AttackTree()
        let resource = PreviewLocation(documentURL: tree.document).resource(for: url(link))
        if case .image = resource { #expect(allowed, "\(link) should be denied") } else { #expect(!allowed, "\(link) should load, got \(resource)") }
    }

    @Test("A symlink to the page's folder can't be used to step out either")
    func symlinkedFolder() throws {
        let tree = try AttackTree()
        try FileManager.default.createSymbolicLink(atPath: tree.docs.appendingPathComponent("up").path, withDestinationPath: "../..")
        let location = PreviewLocation(documentURL: tree.document)
        guard case .denied = location.resource(for: url("marklight-preview://doc/docs/up/secret/secret.png")) else {
            Issue.record("a folder symlink escaped the root")
            return
        }
    }

    @Test("Only in-tree Markdown files open from a link")
    func markdownLinks() throws {
        let tree = try AttackTree()
        let location = PreviewLocation(documentURL: tree.document)
        #expect(location.markdownFile(for: url("marklight-preview://doc/docs/other.md"))?.path == tree.docs.appendingPathComponent("other.md").path)
        #expect(location.markdownFile(for: url("marklight-preview://doc/docs/missing.md")) == nil)
        #expect(location.markdownFile(for: url("marklight-preview://doc/docs/notes.txt")) == nil)
        #expect(location.markdownFile(for: url("marklight-preview://doc/docs/attack.md")) == nil, "the document itself")
        try Data("# Outside\n".utf8).write(to: tree.top.appendingPathComponent("outside.md"))
        #expect(location.markdownFile(for: url("marklight-preview://doc/docs/..%2f..%2foutside.md")) == nil)
        try FileManager.default.createSymbolicLink(atPath: tree.docs.appendingPathComponent("out.md").path, withDestinationPath: "../../outside.md")
        #expect(location.markdownFile(for: url("marklight-preview://doc/docs/out.md")) == nil)
    }

    // MARK: - The bundled sanitizer

    @Test("The bundled DOMPurify is the pinned, verified build")
    func pinnedSanitizer() throws {
        let data = try Data(contentsOf: WebAssets.directory.appendingPathComponent("purify.min.js"))
        let hash = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "db04f45babe88f3ddc26e2e86bf0f1acf5504629e47d18c558c5880cae0d8214ea39b121a5e9b59c491e2b477d644fbf872bdf30db896657f13382ec4607a848")
    }

    // MARK: - A hostile document in a real web view

    @Test("Nothing from a hostile document runs, and only safe images load")
    func hostileDocument() async throws {
        let tree = try AttackTree()
        let h = try PreviewHarness(url: tree.document, size: NSSize(width: 1000, height: 2400))
        defer { h.close() }
        var requests: [String] = []
        h.pane.scheme.requestLogged = { url, resource in requests.append("\(url.absoluteString) \(resource)") }
        try await h.settle()
        await pump(for: 1)

        let page = try await state(h)
        #expect(page.title.isEmpty, "something set the title to \(page.title)")
        #expect(page.dangerousTags.isEmpty, "\(page.dangerousTags)")
        #expect(page.handlers.isEmpty, "\(page.handlers)")
        #expect(page.scriptLinks.isEmpty, "\(page.scriptLinks)")
        #expect(page.forgedOffsets == 0)
        #expect(page.forgedEditable == 0)

        let loaded = Dictionary(page.images.map { ($0["alt"] ?? "", $0["loaded"] == "true") }, uniquingKeysWith: { $0 || $1 })
        for alt in wanted { #expect(loaded[alt] == true, "\(alt) should load: \(requests)") }
        for alt in unwanted { #expect(loaded[alt] != true, "\(alt) should not load") }
        #expect(!requests.contains { $0.contains("secret.png") && $0.contains("image(") }, "\(requests)")

        let probe = try await h.pageWorld("JSON.stringify([String(window.__pwned), typeof window.webkit, typeof DOMPurify, typeof marklight])") as? String
        #expect(probe == #"["undefined","undefined","undefined","undefined"]"#)
    }

    @Test("Raw HTML can't forge offsets, even by closing its holder")
    func forgedOffsets() async throws {
        let tree = try AttackTree()
        let h = try PreviewHarness(url: tree.document)
        defer { h.close() }
        try await h.settle()
        let raw: [Int] = try await h.json("""
        const find = t => [...document.querySelectorAll('#doc p')].find(p => p.textContent === t);
        const forged = find('forged paragraph'), escaped = find('escaped the holder');
        return [forged, escaped].map(p => p && p.closest('[data-raw]') && !p.hasAttribute('data-src') && !p.hasAttribute('data-run')
                                         && !p.hasAttribute('data-caret') && !p.hasAttribute('contenteditable') ? 1 : 0);
        """)
        #expect(raw == [1, 1])
    }

    @Test("Links go to the browser or Marklight, and the preview stays put")
    func links() async throws {
        let tree = try AttackTree()
        let h = try PreviewHarness(url: tree.document, size: NSSize(width: 1000, height: 900))
        defer { h.close() }
        var external: [String] = []
        var markdown: [String] = []
        h.pane.openExternal = { external.append($0.absoluteString) }
        h.pane.openMarkdown = { markdown.append($0.lastPathComponent) }
        try await h.settle()
        let start = h.webView.url

        for text in ["markdown js link", "attribute breakout", "external link", "mail link", "other markdown file",
                     "raw js link", "raw data link", "raw blank link", "raw markdown link", "missing markdown link", "text file link"] {
            let point = try await h.center(of: "a", text: text)
            await pump(for: 0.1)
            await h.click(x: point.x, y: point.y)
            await pump(for: 0.15)
            #expect(h.webView.url == start, "\(text) navigated the preview")
        }

        #expect(Set(external) == ["https://example.com/page", "mailto:someone@example.com", "https://example.com/blank"], "\(external)")
        #expect(markdown == ["other.md", "other.md"], "\(markdown)")
        let title = try await h.js("return document.title") as? String
        #expect(title?.isEmpty == true)
    }

    @Test("Cmd-clicks get the same routing")
    func commandClick() async throws {
        let h = try PreviewHarness(text: "[external](https://example.com/page)\n")
        defer { h.close() }
        var external: [String] = []
        h.pane.openExternal = { external.append($0.absoluteString) }
        try await h.settle()
        let point = try await h.center(of: "a")
        await pump(for: 0.1)
        let start = h.webView.url
        await h.click(x: point.x, y: point.y, modifiers: .command)
        await pump(for: 0.3)
        #expect(external == ["https://example.com/page"])
        #expect(h.webView.url == start)
    }

    @Test("A navigation that isn't a click goes nowhere")
    func nonClickNavigation() async throws {
        let h = try PreviewHarness(text: "text\n")
        defer { h.close() }
        var opened: [URL] = []
        h.pane.openExternal = { opened.append($0) }
        h.pane.openMarkdown = { opened.append($0) }
        try await h.settle()
        let start = h.webView.url
        _ = try await h.js("location.href = 'https://evil.example/moved'")
        await pump(for: 0.3)
        #expect(opened.isEmpty)
        #expect(h.webView.url == start)
        let still = try await h.js("return document.getElementById('doc').textContent") as? String
        #expect(still?.contains("text") == true)
    }

    @Test("The bridge drops anything that doesn't match the contract")
    func bridgeRejects() async throws {
        let h = try PreviewHarness(text: "some text\n")
        defer { h.close() }
        try await h.settle()
        var selections: [Range<Int>] = []
        h.pane.selectionChanged = { selections.append($0) }
        _ = try await h.js("""
        const post = m => window.webkit.messageHandlers.marklight.postMessage(m);
        post('nonsense');
        post({ type: 'ready', extra: 1 });
        post({ type: 'input', inputType: 'insertText', data: 'x' });
        post({ type: 'selection', v: 'one', start: 0, end: 1 });
        post({ type: 'selection', v: 0, start: 5, end: 1 });
        post({ type: 'selection', v: 0, start: -1, end: 1 });
        post({ type: 'selection', v: 99999, start: 0, end: 1 });
        post({ type: 'selection', v: 0, start: 0, end: 1, more: 2 });
        post({ type: 'selection', v: 0, start: 0.5, end: 1 });
        """)
        #expect(await pump(until: { h.pane.rejectedMessages.count == 9 }, timeout: 3), "\(h.pane.rejectedMessages)")
        #expect(selections.isEmpty)
        #expect(h.doc.buffer.text == "some text\n")
    }

    @Test("A web process crash brings the preview back")
    func webProcessCrash() async throws {
        let h = try PreviewHarness(text: "# Title\n")
        defer { h.close() }
        try await h.settle()
        h.pane.webViewWebContentProcessDidTerminate(h.webView)
        await pump(for: 0.2)
        try await h.settle()
        let title = try await h.js("return document.querySelector('h1').textContent") as? String
        #expect(title == "Title")
    }

    // MARK: - The context menu

    @Test("The context menu keeps only what's safe here")
    func contextMenu() {
        let menu = NSMenu()
        func add(_ id: String?) {
            let item = NSMenuItem(title: id ?? "plain", action: nil, keyEquivalent: "")
            item.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add("WKMenuItemIdentifierOpenLink")
        add("WKMenuItemIdentifierOpenLinkInNewWindow")
        add("WKMenuItemIdentifierDownloadLinkedFile")
        add("WKMenuItemIdentifierCopyLink")
        menu.addItem(.separator())
        add("WKMenuItemIdentifierOpenImageInNewWindow")
        add("WKMenuItemIdentifierDownloadImage")
        menu.addItem(.separator())
        add("WKMenuItemIdentifierCopy")
        add("WKMenuItemIdentifierReload")
        add("WKMenuItemIdentifierSomethingNew")
        add(nil)
        menu.addItem(.separator())
        PreviewWebView.filter(menu)
        #expect(menu.items.map(\.title) == ["WKMenuItemIdentifierCopyLink", "", "WKMenuItemIdentifierCopy"])
    }

    // MARK: - The control

    /// The same document with the defences off. If this stops showing attacks, the
    /// tests above aren't detecting anything, however green they look.
    @Test("With the defences off, the same attacks work, so the tests can see them")
    func noDefencesControl() async throws {
        let tree = try AttackTree()
        let url = tree.docs.appendingPathComponent("empty.md")
        try Data().write(to: url)
        let h = try PreviewHarness(url: url, size: NSSize(width: 1000, height: 2400),
                                   defences: PreviewDefences(contentSecurityPolicy: false, pageJavaScriptOff: false))
        defer { h.close() }
        try await h.settle()
        _ = try await h.js("""
        DOMPurify.sanitize = html => {
          const t = document.createElement('template');
          t.innerHTML = html;
          return t.content;
        };
        """)
        let attack = TextCodec.decode(try Data(contentsOf: tree.document)).units
        try h.doc.buffer.apply(Patch(range: 0..<0, replacement: attack, origin: .source))
        try await h.settle()
        await pump(for: 1)

        let page = try await state(h)
        #expect(page.title.hasPrefix("pwned"), "the onerror handler should have run, title is '\(page.title)'")
        #expect(!page.dangerousTags.isEmpty)
        #expect(!page.handlers.isEmpty)
        #expect(!page.scriptLinks.isEmpty)
    }
}
