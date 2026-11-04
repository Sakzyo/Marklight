import AppKit
import MarklightCore

/// One open file. Holds the buffer, and everything between it and the disk.
@objc(MarkdownDocument)
public final class MarkdownDocument: NSDocument {
    public let buffer = Buffer()

    public static let markdownType = "net.daringfireball.markdown"
    /// `defaults write com.example.Marklight autosaveInPlace -bool true`, read at launch.
    static let autosaveKey = "autosaveInPlace"

    private var watcher: FileWatcher?
    private var observer: UUID?
    /// Bytes the user chose to keep their edits over, so they aren't asked again.
    private var declined: Data?
    private var isPrompting = false

    /// Stands in for the reload-or-keep alert. Passes true to reload.
    public var externalChangePrompt: ((@escaping (Bool) -> Void) -> Void)?

    public override init() {
        super.init()
        hasUndoManager = false // the buffer owns undo
        observer = buffer.addObserver { [weak self] _ in self?.bufferChanged() }
    }

    /// Opens a symlink as its target, for documents not opened through the controller.
    public convenience init(contentsOf url: URL, ofType typeName: String) throws {
        self.init()
        let file = url.resolvingFileSymlinks()
        try read(from: file, ofType: typeName)
        fileURL = file
        fileType = typeName
        fileModificationDate = FileWatcher.modificationDate(of: file)
    }

    // Silent in-place saves interact badly with git and file watchers.
    public override class var autosavesInPlace: Bool { UserDefaults.standard.bool(forKey: autosaveKey) }

    public override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    private func bufferChanged() {
        updateChangeCount(buffer.isDirty ? .changeDone : .changeCleared)
    }

    public override var fileURL: URL? {
        didSet {
            watcher = fileURL.map { url in
                FileWatcher(url: url) { [weak self] in self?.checkForExternalChange() }
            }
            for controller in windowControllers {
                (controller as? EditorWindowController)?.documentMoved(to: fileURL)
            }
        }
    }

    public override func close() {
        watcher = nil
        super.close()
    }

    // MARK: - Reading and writing

    public override func read(from data: Data, ofType typeName: String) throws {
        buffer.reload(contentsOf: data)
    }

    public override func data(ofType typeName: String) throws -> Data {
        buffer.serialized()
    }

    /// Safe save keeps the mode and xattrs but replaces the inode, which would cut
    /// a hard link off from the file, so hard-linked files are written in place.
    public override func writeSafely(to url: URL, ofType typeName: String, for operation: NSDocument.SaveOperationType) throws {
        let data = buffer.serialized()
        let overwrites = operation == .saveOperation || operation == .autosaveInPlaceOperation
        if overwrites, FileWatcher.linkCount(of: url) > 1 {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            fileModificationDate = FileWatcher.modificationDate(of: url)
        } else {
            try super.writeSafely(to: url, ofType: typeName, for: operation)
        }
        if overwrites || operation == .saveAsOperation {
            buffer.markSaved(data)
            declined = nil
        }
    }

    // MARK: - External changes

    public override func presentedItemDidChange() {
        DispatchQueue.main.async { [weak self] in self?.checkForExternalChange() }
    }

    /// Also runs when the window comes forward, in case a change went unnoticed.
    func checkForExternalChange() {
        guard !isPrompting, let url = fileURL, let data = FileWatcher.read(url),
              !buffer.matchesSavedFile(data), data != declined else { return }
        guard buffer.isDirty else { return adopt(data, from: url) }
        isPrompting = true
        let decide: (Bool) -> Void = { [weak self] reload in
            guard let self else { return }
            isPrompting = false
            if reload {
                adopt(data, from: url)
            } else {
                declined = data
                fileModificationDate = FileWatcher.modificationDate(of: url) // so Save doesn't warn again
            }
        }
        if let externalChangePrompt {
            externalChangePrompt(decide)
        } else {
            promptToReload(decide)
        }
    }

    private func adopt(_ data: Data, from url: URL) {
        buffer.reload(contentsOf: data)
        declined = nil
        fileModificationDate = FileWatcher.modificationDate(of: url)
    }

    private func promptToReload(_ decide: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(displayName ?? "This file") changed on disk"
        alert.informativeText = "You have unsaved edits. Reloading discards them. Keeping them means saving will replace the version on disk."
        alert.addButton(withTitle: "Keep My Edits")
        alert.addButton(withTitle: "Reload")
        if let window = windowControllers.first?.window {
            alert.beginSheetModal(for: window) { decide($0 == .alertSecondButtonReturn) }
        } else {
            decide(alert.runModal() == .alertSecondButtonReturn)
        }
    }
}

/// Watches a path for changes from outside the app. A vnode source sees writes
/// that skip file coordination, and `git checkout` replaces the file, so the
/// watch has to be set up again after a rename or delete.
final class FileWatcher {
    private let url: URL
    private let changed: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, changed: @escaping () -> Void) {
        self.url = url
        self.changed = changed
        arm()
    }

    deinit { source?.cancel() }

    private func arm() {
        source?.cancel()
        source = nil
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Mid-replace, or gone. Look again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, FileManager.default.fileExists(atPath: self.url.path) else { return }
                self.arm()
                self.changed()
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) { self.arm() }
            self.changed()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    static func read(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &error) {
            result = try? Data(contentsOf: $0)
        }
        return result
    }

    static func linkCount(of url: URL) -> Int {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int(info.st_nlink) : 1
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
