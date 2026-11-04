import EditCore
import Foundation

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

// Round-trip check: for every leaf, serializing its atoms must reproduce the
// source bytes exactly. This is the zero-diff guard for the whole design.
//
//   spike4-corpus <file>...
//   spike4-corpus --fuzz <ops per file> <seed> <file>...

if CommandLine.arguments[safe: 1] == "--fuzz" {
    let ops = Int(CommandLine.arguments[2])!
    var fuzz = Fuzzer(rng: SplitMix(state: UInt64(CommandLine.arguments[3])!))
    var files = 0
    for path in CommandLine.arguments.dropFirst(4) {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { continue }
        if data.count > 120_000 { continue } // each op re-parses the whole file
        files += 1
        fuzz.run(file: URL(fileURLWithPath: path).lastPathComponent, text: text, ops: ops)
    }
    let total = fuzz.counts.values.reduce(0) { $0 + $1.ok + $1.noop + $1.refused }
    print("files \(files), operations \(total)")
    print("| Operation | Applied | No-op | Refused |")
    print("|---|---|---|---|")
    for (k, v) in fuzz.counts.sorted(by: { $0.key < $1.key }) { print("| \(k) | \(v.ok) | \(v.noop) | \(v.refused) |") }
    print("\nviolations: \(fuzz.violations.values.reduce(0, +))")
    for (k, n) in fuzz.violations.sorted(by: { $0.value > $1.value }) { print("  \(n)  \(k)") }
    print("\nrefusal reasons:")
    for (k, n) in fuzz.refusals.sorted(by: { $0.value > $1.value }) { print("  \(n)  \(k)") }
    let t = fuzz.times.sorted()
    if !t.isEmpty { print(String(format: "\nedit time: median %.2f ms, p95 %.2f ms, max %.2f ms", t[t.count / 2], t[t.count * 95 / 100], t.last!)) }
    print("")
    for e in fuzz.examples { print(e) }
    print("")
    for e in fuzz.refusedExamples { print("refused: \(e)") }
    exit(0)
}

if CommandLine.arguments[safe: 1] == "--timing" {
    // A keystroke in the middle of each file, end to end except the DOM update.
    for path in CommandLine.arguments.dropFirst(2) {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { continue }
        let editor = Editor(text: text)
        let clock = ContinuousClock()
        var parse = Duration.zero, type = Duration.zero, render = Duration.zero
        parse = clock.measure { _ = DocModel(units: editor.units) }
        let leaves = editor.doc.root.allLeaves().filter { !$0.opaque && !$0.atoms.isEmpty }
        guard let leaf = leaves.dropFirst(leaves.count / 2).first(where: { $0.atoms.count > 2 && $0.atoms[1].range != nil }) else { continue }
        var at = leaf.atoms[1].range!.lowerBound
        let n = 10
        for _ in 0..<n {
            type += clock.measure { at = editor.perform(.insert("x", at..<at)).caret }
            render += clock.measure { _ = Renderer.html(editor.doc) }
        }
        func ms(_ d: Duration) -> Double { (Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
        print(String(format: "%7.0f KB  parse+anchor %7.2f ms  keystroke %7.2f ms  full render %7.2f ms", Double(data.count) / 1024, ms(parse), ms(type) / Double(n), ms(render) / Double(n)))
    }
    exit(0)
}

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
