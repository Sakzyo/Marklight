import Foundation
import UniformTypeIdentifiers
import WebKit

/// The preview's only origin: `marklight-preview://doc/`.
///
/// - `/` is the preview page itself, served with the CSP header.
/// - Any other path is a file relative to the document's folder, served only if
///   its real path (after resolving symlinks) is inside that folder tree and it
///   is a regular file with an image type.
enum PreviewScheme {
    static let name = "marklight-preview"
    static let host = "doc"
    static let pageURL = URL(string: "\(name)://\(host)/")!

    /// Scripts: none from the page at all. Marklight's own JS runs in an
    /// isolated WKContentWorld injected by the app, which the page CSP doesn't
    /// govern (checked by this spike).
    static let csp = [
        "default-src 'none'",
        "script-src 'none'",
        "style-src 'unsafe-inline'",
        "img-src \(name): data:",
        "media-src \(name):",
        "font-src 'none'",
        "connect-src 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "object-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "svg": "image/svg+xml", "bmp": "image/bmp",
        "ico": "image/x-icon",
    ]
}

enum Resolution: Equatable {
    case page
    case file(path: String, mimeType: String)
    case denied(String)
}

/// The file-access policy, separate from WebKit so it can be tested directly.
struct PathPolicy {
    /// Real path of the document's folder (no trailing slash).
    let root: String

    init(documentFolder: URL) {
        root = PathPolicy.realPath(documentFolder.path) ?? documentFolder.path
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func resolve(_ url: URL) -> Resolution {
        guard url.scheme == PreviewScheme.name else { return .denied("wrong scheme") }
        guard url.host == PreviewScheme.host else { return .denied("wrong host \(url.host ?? "nil")") }
        // URL.path is percent-decoded, so %2e%2e and %2f arrive as ".." and "/".
        let path = url.path
        if path == "/" || path.isEmpty { return .page }
        guard !path.contains("\0") else { return .denied("NUL in path") }
        let joined = (root as NSString).appendingPathComponent(path)
        guard let real = PathPolicy.realPath(joined) else { return .denied("no such file") }
        guard real.hasPrefix(root + "/") else { return .denied("outside document folder (\(real))") }
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .denied("not a regular file") }
        let ext = (real as NSString).pathExtension.lowercased()
        guard let mime = PreviewScheme.imageTypes[ext] else { return .denied("not an image type (.\(ext))") }
        return .file(path: real, mimeType: mime)
    }
}

final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    let policy: PathPolicy
    let page: () -> String
    var cspEnabled = true
    private(set) var log: [(url: String, result: Resolution)] = []

    init(policy: PathPolicy, page: @escaping () -> String) {
        self.policy = policy
        self.page = page
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let result = policy.resolve(url)
        log.append((url.absoluteString, result))
        switch result {
        case .page:
            var headers = ["Content-Type": "text/html; charset=utf-8", "X-Content-Type-Options": "nosniff"]
            if cspEnabled { headers["Content-Security-Policy"] = PreviewScheme.csp }
            respond(task, url: url, status: 200, body: Data(page().utf8), headers: headers)
        case .file(let path, let mime):
            let body = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            respond(task, url: url, status: 200, body: body, headers: [
                "Content-Type": mime,
                // An SVG opened as a document can run script; as an <img> it can't.
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
                "X-Content-Type-Options": "nosniff",
            ])
        case .denied:
            respond(task, url: url, status: 403, body: Data(), headers: ["Content-Type": "text/plain"])
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int, body: Data, headers: [String: String]) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
