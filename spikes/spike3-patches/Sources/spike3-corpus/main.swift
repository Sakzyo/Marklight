import EditCore
import Foundation

// Round-trip check: for every leaf, serializing its atoms must reproduce the
// source bytes exactly. This is the zero-diff guard for the whole design.
//
//   spike3-corpus <file>...

var leaves = 0, opaque = 0, mismatched = 0, files = 0, skipped = 0
var reasons: [String: Int] = [:]
var examples: [String] = []
let clock = ContinuousClock()
var parseTime = Duration.zero

func kind(_ reason: String) -> String {
    reason.replacingOccurrences(of: #"\d+"#, with: "N", options: .regularExpression)
}

for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { skipped += 1; continue }
    files += 1
    let units = Array(text.utf16)
    var doc: DocModel!
    parseTime += clock.measure { doc = DocModel(units: units) }
    for leaf in doc.root.allLeaves() {
        leaves += 1
        if leaf.opaque {
            opaque += 1
            let r = kind(leaf.opaqueReason ?? "?")
            reasons[r, default: 0] += 1
            if examples.count < 12 {
                let s = String(decoding: units[leaf.range.lowerBound..<min(leaf.range.upperBound, leaf.range.lowerBound + 70)], as: UTF16.self)
                examples.append("\(URL(fileURLWithPath: path).lastPathComponent): \(leaf.opaqueReason ?? "") in \(s.debugDescription)")
            }
            continue
        }
        if case .code = leaf.kind { continue }
        let written = Serializer.write(leaf.atoms, source: units)
        if written != Array(units[leaf.content]) {
            mismatched += 1
            if examples.count < 24 {
                examples.append("MISMATCH \(URL(fileURLWithPath: path).lastPathComponent): \(String(decoding: units[leaf.content], as: UTF16.self).prefix(70).debugDescription) vs \(String(decoding: written, as: UTF16.self).prefix(70).debugDescription)")
            }
        }
    }
}
print("files \(files), skipped (not UTF-8) \(skipped), leaves \(leaves)")
print("opaque (anchoring failed) \(opaque), round-trip mismatches \(mismatched)")
print("parse + anchor time \(parseTime)")
for (r, n) in reasons.sorted(by: { $0.value > $1.value }) { print("  \(n)  \(r)") }
for e in examples { print(e) }
