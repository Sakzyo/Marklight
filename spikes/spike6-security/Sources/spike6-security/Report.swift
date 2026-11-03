import Foundation

@MainActor func printPolicyTable(docs: URL) {
    let policy = PathPolicy(documentFolder: docs)
    let base = PreviewScheme.pageURL
    let cases = ["images/ok.png", "./images/sub/nested.png", "link-in.png", "images/with%20space.png", "images/evil.svg",
                 "../assets/shared.png", "../../secret/secret.png", "../../../../../../../../etc/passwd",
                 "%2e%2e/%2e%2e/secret/secret.png", "..%2f..%2fsecret%2fsecret.png", "/etc/hosts", "link-out.png", "notes.txt",
                 "images", "other.md", "images/ok.png%00.txt", "marklight-preview://elsewhere/etc/hosts"]
    print("## Path policy (called directly)\n")
    print("| Reference | Resolved URL | Result |")
    print("|---|---|---|")
    for ref in cases {
        guard let url = URL(string: ref, relativeTo: base)?.absoluteURL else { print("| `\(ref)` | unparseable | denied |"); continue }
        print("| `\(ref)` | `\(url.absoluteString)` | \(describe(policy.resolve(url), docs: policy.root)) |")
    }
}

func describe(_ r: Resolution, docs: String) -> String {
    switch r {
    case .page: return "page"
    case .file(let path, let mime): return "**served** \(path.replacingOccurrences(of: docs, with: "<docs>")) (\(mime))"
    case .denied(let why): return "denied: \(why.replacingOccurrences(of: docs, with: "<docs>"))"
    }
}

@MainActor func printResults(_ results: [RunResult]) {
    print("\n## Attack outcomes by defence combination\n")
    print("| Check | " + results.map { $0.defences.description }.joined(separator: " | ") + " |")
    print("|---|" + results.map { _ in "---|" }.joined())
    func row(_ name: String, _ f: (RunResult) -> String) {
        print("| \(name) | " + results.map(f).joined(separator: " | ") + " |")
    }
    // Union of image sources across modes, in document order of the baseline run.
    var imageNames: [String] = []
    for r in results.reversed() {
        for name in (r.state["images"] as? [[Any]])?.compactMap({ $0.first as? String }) ?? [] where !imageNames.contains(name) {
            imageNames.append(name)
        }
    }
    for name in imageNames {
        row("img `\(name)`") { r in
            let images = r.state["images"] as? [[Any]] ?? []
            guard let entry = images.first(where: { ($0.first as? String) == name }) else { return "removed" }
            return (entry.last as? Bool) == true ? "loaded" : "blocked"
        }
    }
    row("document.title after render") { r in (r.state["title"] as? String).map { $0.isEmpty ? "unchanged" : "**\($0)**" } ?? "?" }
    row("document.title after clicks") { r in r.titleAfterClicks.isEmpty ? "unchanged" : "**\(r.titleAfterClicks)**" }
    row("window.__pwned in page world") { r in r.pageWorld.first.map { $0 == "undefined" ? "undefined" : "**\($0)**" } ?? "?" }
    row("page world sees window.webkit") { r in r.pageWorld.count > 1 ? r.pageWorld[1] : "?" }
    row("page world sees DOMPurify / marklight") { r in r.pageWorld.count > 3 ? "\(r.pageWorld[2]) / \(r.pageWorld[3])" : "?" }
    row("dangerous tags left in DOM") { r in list(r.state["dangerousTags"]) }
    row("event-handler attributes left") { r in list(r.state["handlers"]) }
    row("javascript:/data: links left") { r in list(r.state["scriptLinks"]) }
    row("still on preview page after clicks") { r in r.stillOnPage ? "yes" : "**NO**" }
    row("external opens (would go to browser)") { r in r.controller.externalOpens.joined(separator: "<br>").ifEmpty("none") }
    row("Markdown files opened in Marklight") { r in r.controller.internalOpens.joined(separator: "<br>").ifEmpty("none") }
    row("rejected bridge messages") { r in r.controller.rejectedMessages.isEmpty ? "none" : "\(r.controller.rejectedMessages.count)" }
    row("CSP violations reported") { r in list(r.state["violations"]) }

    for r in results {
        print("\n### Requests and navigations: \(r.defences)\n")
        for entry in r.handler.log { print("- request `\(entry.url)` → \(describe(entry.result, docs: r.handler.policy.root))") }
        for n in r.controller.navigations { print("- navigation \(n)") }
    }
}

func list(_ value: Any?) -> String {
    let items = (value as? [String]) ?? []
    return items.isEmpty ? "none" : items.joined(separator: "<br>").replacingOccurrences(of: "|", with: "\\|")
}
