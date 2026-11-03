import AppKit
import Foundation

enum SaveStrategy: String, CaseIterable {
    /// `Data.write(to:options: .atomic)` on the path as given.
    case atomic
    /// Truncate and rewrite the existing file through its descriptor.
    case inPlace
    /// Resolve symlinks, then `Data.write(.atomic)` on the target.
    case resolvedAtomic
    /// Resolve symlinks, write a temp file next to the target, then
    /// `FileManager.replaceItemAt` (what NSDocument's safe save builds on).
    case safeReplace
    /// NSDocument `writeSafely(to:ofType:for: .saveOperation)` with the path as given.
    case nsDocument

    func write(_ data: Data, to url: URL) throws {
        switch self {
        case .atomic:
            try data.write(to: url, options: .atomic)
        case .inPlace:
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        case .resolvedAtomic:
            try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
        case .safeReplace:
            let target = url.resolvingSymlinksInPath()
            let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: target, create: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let temp = scratch.appendingPathComponent(target.lastPathComponent)
            try data.write(to: temp)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        case .nsDocument:
            let doc = SpikeDocument()
            doc.payload = data
            doc.fileURL = url
            try doc.writeSafely(to: url, ofType: "public.plain-text", for: .saveOperation)
        }
    }
}

final class SpikeDocument: NSDocument {
    var payload = Data()
    override func read(from data: Data, ofType typeName: String) throws { payload = data }
    override func data(ofType typeName: String) throws -> Data { payload }
}

// MARK: - File-system matrix

struct Snapshot {
    let isSymlink: Bool
    let linkTarget: String?
    let inode: UInt64
    let mode: Int
    let xattr: String?
    let hardLinkCount: Int
    let realContent: String
    let hardLinkContent: String
}

func xattr(_ path: String, _ name: String) -> String? {
    let size = getxattr(path, name, nil, 0, 0, 0)
    guard size > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    getxattr(path, name, &buf, size, 0, 0)
    return String(decoding: buf, as: UTF8.self)
}

func snapshot(dir: URL, writtenPath: URL) -> Snapshot {
    let fm = FileManager.default
    let real = dir.appendingPathComponent("real/doc.md")
    let attrs = (try? fm.attributesOfItem(atPath: real.path)) ?? [:]
    let linkAttrs = (try? fm.attributesOfItem(atPath: writtenPath.path)) ?? [:]
    return Snapshot(
        isSymlink: (linkAttrs[.type] as? FileAttributeType) == .typeSymbolicLink,
        linkTarget: try? fm.destinationOfSymbolicLink(atPath: writtenPath.path),
        inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
        mode: (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0,
        xattr: xattr(real.path, "com.marklight.spike"),
        hardLinkCount: (attrs[.referenceCount] as? NSNumber)?.intValue ?? 0,
        realContent: (try? String(contentsOf: real, encoding: .utf8)) ?? "?",
        hardLinkContent: (try? String(contentsOf: dir.appendingPathComponent("real/hard.md"), encoding: .utf8)) ?? "?"
    )
}

/// dir/real/doc.md (0755, xattr, hard link real/hard.md), dir/link.md -> real/doc.md
func makeScene() throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("spike2-fs-\(UUID().uuidString)")
    let real = dir.appendingPathComponent("real")
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    let doc = real.appendingPathComponent("doc.md")
    try Data("OLD\n".utf8).write(to: doc)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: doc.path)
    let value = Array("kept".utf8)
    setxattr(doc.path, "com.marklight.spike", value, value.count, 0, 0)
    try fm.linkItem(at: doc, to: real.appendingPathComponent("hard.md"))
    try fm.createSymbolicLink(atPath: dir.appendingPathComponent("link.md").path, withDestinationPath: "real/doc.md")
    return dir
}

@MainActor func runFileSystemMatrix() {
    print("| Strategy | Opened via | Symlink kept | Target updated | Inode kept | Mode 0755 kept | xattr kept | Hard link sees edit |")
    print("|---|---|---|---|---|---|---|---|")
    for strategy in SaveStrategy.allCases {
        for via in ["real/doc.md", "link.md"] {
            do {
                let dir = try makeScene()
                defer { try? FileManager.default.removeItem(at: dir) }
                let path = dir.appendingPathComponent(via)
                let before = snapshot(dir: dir, writtenPath: path)
                try strategy.write(Data("NEW\n".utf8), to: path)
                let after = snapshot(dir: dir, writtenPath: path)
                let symlink = via == "link.md" ? (after.isSymlink && after.linkTarget == before.linkTarget ? "yes" : "**NO**") : "n/a"
                func mark(_ ok: Bool) -> String { ok ? "yes" : "**NO**" }
                print("| \(strategy.rawValue) | \(via) | \(symlink) | \(mark(after.realContent == "NEW\n")) | \(mark(after.inode == before.inode)) | \(mark(after.mode == 0o755)) | \(mark(after.xattr == "kept")) | \(mark(after.hardLinkContent == "NEW\n")) |")
            } catch {
                print("| \(strategy.rawValue) | \(via) | error: \(error.localizedDescription) |")
            }
        }
    }

    // How does NSDocument record a file opened through a symlink?
    do {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link.md")
        let doc = try SpikeDocument(contentsOf: link, ofType: "public.plain-text")
        let recorded = doc.fileURL?.path.replacingOccurrences(of: dir.path, with: "<dir>") ?? "nil"
        print("\nNSDocument(contentsOf: <dir>/link.md).fileURL = \(recorded)")
    } catch {
        print("\nNSDocument open via symlink failed: \(error)")
    }
}
