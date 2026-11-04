import Foundation
import WebKit

/// The preview's only origin: `marklight-preview://doc/`. See
/// `spikes/spike6-security/REPORT.md` for why each of these is what it is.
enum PreviewScheme {
    static let name = "marklight-preview"
    static let host = "doc"

    /// No script from the page at all. Marklight's own JS runs in an isolated
    /// content world, which this doesn't govern.
    static func csp(remoteImages: Bool) -> String {
        [
            "default-src 'none'",
            "script-src 'none'",
            "style-src 'unsafe-inline'",
            "img-src \(name): data:" + (remoteImages ? " https:" : ""),
            "media-src 'none'",
            "font-src 'none'",
            "connect-src 'none'",
            "frame-src 'none'",
            "child-src 'none'",
            "object-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
        ].joined(separator: "; ")
    }

    /// For served files. An SVG opened as a document could otherwise run script.
    static let fileCSP = "default-src 'none'; style-src 'unsafe-inline'"

    static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "svg": "image/svg+xml", "bmp": "image/bmp",
        "ico": "image/x-icon",
    ]

    static let markdownExtensions: Set<String> = ["md", "markdown"]
}

/// What a request to the preview's origin gets.
enum PreviewResource: Equatable {
    case page
    case image(path: String, mimeType: String)
    case denied(String)
}

/// Where a document sits in the preview's origin, and what it may read.
///
/// The access root is the git repository around the document, or else its folder.
/// The page is served at the document's path below that root, so `../` resolves as
/// it does on disk.
struct PreviewLocation: Equatable {
    /// The real path of the access root. An unsaved document has none, and reads nothing.
    let root: String?
    /// The document's path below the root, starting with `/`. Not percent-encoded.
    let pagePath: String

    init(documentURL: URL?) {
        guard let documentURL else {
            root = nil
            pagePath = "/Untitled.md"
            return
        }
        let file = realPath(documentURL.path) ?? documentURL.path
        let folder = (file as NSString).deletingLastPathComponent
        let root = PreviewLocation.accessRoot(from: folder)
        self.root = root
        pagePath = root == "/" ? file : String(file.dropFirst(root.count))
    }

    /// The nearest folder holding `.git`, which is a file in a worktree or submodule.
    static func accessRoot(from folder: String) -> String {
        var candidate = folder
        while true {
            if FileManager.default.fileExists(atPath: (candidate as NSString).appendingPathComponent(".git")) { return candidate }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { return folder }
            candidate = parent
        }
    }

    var pageURL: URL {
        var components = URLComponents()
        components.scheme = PreviewScheme.name
        components.host = PreviewScheme.host
        components.path = pagePath
        return components.url!
    }

    /// The file a URL names, if it's inside the root. Symlinks and `..` are resolved
    /// first, so neither can reach out of it.
    private func fileInsideRoot(_ url: URL) -> Result<String, Denial> {
        guard url.scheme == PreviewScheme.name else { return .failure(Denial("wrong scheme")) }
        guard url.host == PreviewScheme.host else { return .failure(Denial("wrong host")) }
        guard let root else { return .failure(Denial("no access root")) }
        // URL.path is percent-decoded, so %2e%2e and %2f arrive as `..` and `/`.
        let path = url.path
        guard !path.contains("\0") else { return .failure(Denial("NUL in path")) }
        guard let real = realPath((root as NSString).appendingPathComponent(path)) else { return .failure(Denial("no such file")) }
        guard real.hasPrefix(root == "/" ? root : root + "/") else { return .failure(Denial("outside the access root")) }
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(Denial("not a regular file")) }
        return .success(real)
    }

    private struct Denial: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    func resource(for url: URL) -> PreviewResource {
        if url.scheme == PreviewScheme.name, url.host == PreviewScheme.host, url.path == pagePath { return .page }
        switch fileInsideRoot(url) {
        case .failure(let denial):
            return .denied(denial.reason)
        case .success(let real):
            let suffix = (real as NSString).pathExtension.lowercased()
            guard let mimeType = PreviewScheme.imageTypes[suffix] else { return .denied("not an image type") }
            return .image(path: real, mimeType: mimeType)
        }
    }

    /// The Markdown file a link names, if it's another document in the tree.
    func markdownFile(for url: URL) -> URL? {
        guard url.path != pagePath, case .success(let real) = fileInsideRoot(url),
              PreviewScheme.markdownExtensions.contains((real as NSString).pathExtension.lowercased()) else { return nil }
        return URL(fileURLWithPath: real)
    }
}

/// `realpath`, which resolves every symlink and `..`, or nil if the file is missing.
private func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Serves the preview page and the images it may show. Images are read off the
/// main thread, so a large one can't hold up typing.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    var location: PreviewLocation
    var csp: String?
    var page: () -> String
    /// Called with each request and its outcome.
    var requestLogged: ((URL, PreviewResource) -> Void)?

    private var running: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private let queue = DispatchQueue(label: "marklight.preview.files", qos: .userInitiated)

    init(location: PreviewLocation, page: @escaping () -> String) {
        self.location = location
        self.page = page
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let resource = location.resource(for: url)
        requestLogged?(url, resource)
        switch resource {
        case .page:
            var headers = ["Content-Type": "text/html; charset=utf-8", "X-Content-Type-Options": "nosniff"]
            if let csp { headers["Content-Security-Policy"] = csp }
            respond(task, url: url, status: 200, body: Data(page().utf8), headers: headers)
        case .image(let path, let mimeType):
            let id = ObjectIdentifier(task)
            running[id] = task
            queue.async { [weak self] in
                let body = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
                DispatchQueue.main.async {
                    // A task WebKit stopped mustn't be answered: that raises an exception.
                    guard let self, let task = self.running.removeValue(forKey: id) else { return }
                    self.respond(task, url: url, status: 200, body: body, headers: [
                        "Content-Type": mimeType,
                        "Content-Security-Policy": PreviewScheme.fileCSP,
                        "X-Content-Type-Options": "nosniff",
                    ])
                }
            }
        case .denied:
            respond(task, url: url, status: 403, body: Data(), headers: ["Content-Type": "text/plain"])
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running[ObjectIdentifier(task)] = nil
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int, body: Data, headers: [String: String]) {
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(body)
        task.didFinish()
    }
}
