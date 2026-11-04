import AppKit

public enum MarklightApplication {
    @MainActor public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // The first controller created becomes the shared one, so this has to
        // happen before anything asks for it.
        _ = DocumentController()
        app.mainMenu = MainMenu.make()
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
}

/// Opens a symlink as the file it points to: NSDocument can't save through a
/// symlink, and the link has to survive (`spikes/spike2-io/REPORT.md`).
public final class DocumentController: NSDocumentController {
    public override func openDocument(withContentsOf url: URL, display: Bool,
                                      completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        super.openDocument(withContentsOf: url.resolvingFileSymlinks(), display: display, completionHandler: completionHandler)
    }
}

extension URL {
    /// `realpath`, unlike `resolvingSymlinksInPath`, keeps `/private` in temporary paths.
    func resolvingFileSymlinks() -> URL {
        guard let resolved = realpath(path, nil) else { return self }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
