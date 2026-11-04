import Foundation

/// The preview's bundled files. In the app they're in `Contents/Resources/web`.
/// Under `swift test` and `swift run` there's no bundle, so they're read from the
/// repository.
enum WebAssets {
    static let directory: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("preview.js").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/web")
    }()

    static func text(_ name: String) -> String {
        (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
}
