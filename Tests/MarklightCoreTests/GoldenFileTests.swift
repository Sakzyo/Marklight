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
}

@Suite("Golden files")
struct GoldenFileTests {
    @Test("Open, no-op, save is byte-identical", arguments: Fixtures.all)
    func noOpRoundTrip(name: String) throws {
        let original = try Data(contentsOf: Fixtures.directory.appendingPathComponent(name))
        let buffer = Buffer(contentsOf: original)
        #expect(buffer.serialized() == original, "\(name) changed on no-op save")
    }

    @Test("Fixtures folder exists")
    func fixturesFolderExists() {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: Fixtures.directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
