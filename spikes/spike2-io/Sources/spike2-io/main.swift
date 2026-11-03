import AppKit
import CryptoKit
import Foundation

// spike2-io: zero-diff file I/O experiments.
//
//   spike2-io roundtrip <file>...   decode, pass through NSTextView, encode; compare in memory
//   spike2-io save <file>           open and save the file in place with no edits (used by run.sh)
//   spike2-io fs                    write-strategy matrix: inode, mode, xattrs, hard links, symlinks

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// What the source pane would hold: the text after a trip through NSTextView.
@MainActor func throughTextView(_ text: String) -> String {
    let view = NSTextView(usingTextLayoutManager: true) // TextKit 2
    view.string = text
    return view.string
}

/// Foundation's convenience path, to show what a naive implementation loses.
func naiveRoundTrip(_ url: URL) -> String {
    var used = String.Encoding.utf8
    guard let text = try? String(contentsOf: url, usedEncoding: &used) else { return "fails to open" }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard (try? text.write(to: tmp, atomically: true, encoding: used)) != nil,
          let saved = try? Data(contentsOf: tmp), let original = try? Data(contentsOf: url) else { return "fails to save" }
    return saved == original ? "identical" : "CHANGED (\(original.count)→\(saved.count) bytes, \(used))"
}

@MainActor func roundtrip(_ paths: [String]) {
    print("| File | Bytes | Detected | Text survives NSTextView | Model round-trip | Insert at end of line 1 is local | Naive Foundation round-trip |")
    print("|---|---|---|---|---|---|---|")
    for path in paths {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { print("| \(url.lastPathComponent) | unreadable |"); continue }
        var decoded = TextCodec.decode(data)
        let viewText = throughTextView(decoded.text)
        let survives = exactlyEqual(viewText, decoded.text)
        decoded.text = viewText
        let encoded = TextCodec.encode(decoded)
        let detected = decoded.encoding.rawValue + (decoded.hasBOM ? "+BOM" : "")
        let result = encoded == data ? "identical" : "CHANGED"
        print("| \(url.lastPathComponent) | \(data.count) | \(detected) | \(survives ? "yes" : "NO") | \(result) | \(editIsLocal(decoded) ? "yes" : "NO") | \(naiveRoundTrip(url)) |")
    }
}

/// Insert "✏️" before the first line break (or at the end) and check that the
/// saved bytes equal the original with only the inserted bytes added.
func editIsLocal(_ file: DecodedFile) -> Bool {
    guard file.encoding != .raw else { return true }
    let original = TextCodec.encode(file)
    let scalars = Array(file.text.unicodeScalars)
    let index = scalars.firstIndex { $0 == "\n" || $0 == "\r" } ?? scalars.count
    var edited = file
    var prefix = String.UnicodeScalarView(); prefix.append(contentsOf: scalars[..<index])
    var suffix = String.UnicodeScalarView(); suffix.append(contentsOf: scalars[index...])
    edited.text = String(prefix) + "✏️" + String(suffix)
    var inserted = file
    inserted.text = String(prefix)
    let head = TextCodec.encode(inserted)
    inserted.text = "✏️"
    var mid = TextCodec.encode(inserted)
    if file.hasBOM { mid = mid.dropFirst(file.encoding == .utf8 || file.encoding == .utf8Escaped ? 3 : 2) }
    let expected = head + mid + original.dropFirst(head.count)
    return TextCodec.encode(edited) == expected
}

/// Open, no-op, save in place through the recommended path.
@MainActor func save(_ path: String) throws {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    var decoded = TextCodec.decode(data)
    decoded.text = throughTextView(decoded.text)
    try SaveStrategy.safeReplace.write(TextCodec.encode(decoded), to: url)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "roundtrip": MainActor.assumeIsolated { roundtrip(Array(args.dropFirst())) }
case "save":
    do { try MainActor.assumeIsolated { for p in args.dropFirst() { try save(p) } } }
    catch { FileHandle.standardError.write("save failed: \(error)\n".data(using: .utf8)!); exit(1) }
case "fs": MainActor.assumeIsolated { runFileSystemMatrix() }
default:
    print("usage: spike2-io roundtrip <file>... | save <file>... | fs")
    exit(2)
}
