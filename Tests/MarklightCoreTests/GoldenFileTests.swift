import CryptoKit
import Foundation
import Testing
@testable import MarklightCore

/// Golden-file suite: open, no-op, save must be byte-identical for every fixture.
///
/// Fixtures live in `Tests/Fixtures/` and are append-only (see `AGENTS.md`).
/// They're read from the source tree rather than bundled as resources so the
/// bytes on disk are exactly the bytes under test.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// Every regular file in the fixtures folder, sorted, excluding dotfiles.
    static var all: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite("Golden files")
struct GoldenFileTests {
    @Test("Open, no-op, save is byte-identical", arguments: Fixtures.all)
    func noOpRoundTrip(name: String) throws {
        let original = try Fixtures.data(name)
        let buffer = Buffer(contentsOf: original)
        #expect(sha256(buffer.serialized()) == sha256(original), "\(name) changed on no-op save")
    }

    @Test("Decoding then encoding is byte-identical, without the saved-bytes shortcut", arguments: Fixtures.all)
    func encoderRoundTrip(name: String) throws {
        let original = try Fixtures.data(name)
        let decoded = TextCodec.decode(original)
        #expect(decoded.format.encoding != .raw, "\(name) fell back to raw")
        #expect(TextCodec.encode(decoded.units, format: decoded.format) == original, "\(name) changed by the encoder")
    }

    @Test("An edit changes only its range, and undo restores the bytes", arguments: Fixtures.all)
    func editAndUndo(name: String) throws {
        let original = try Fixtures.data(name)
        let buffer = Buffer(contentsOf: original)
        let at = buffer.units.count / 2
        let offset = (0xDC00..<0xE000).contains(at < buffer.units.count ? buffer.units[at] : 0) ? at + 1 : at
        let text = Array("✏️".utf16)
        try buffer.apply(Patch(range: offset..<offset, replacement: text, origin: .source))
        #expect(buffer.isDirty)
        #expect(Array(buffer.units[offset..<offset + text.count]) == text)
        buffer.undo()
        #expect(!buffer.isDirty)
        #expect(buffer.serialized() == original)
        buffer.redo()
        #expect(buffer.isDirty)
    }

    @Test("Fixtures folder exists")
    func fixturesFolderExists() {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: Fixtures.directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
