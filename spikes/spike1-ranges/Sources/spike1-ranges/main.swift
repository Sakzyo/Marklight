import Foundation
import Markdown

// spike1-ranges: does swift-markdown locate every node precisely?
//
//   spike1-ranges dump <file>          every node: type, range, offsets, source slice
//   spike1-ranges check <file>...      per-type pass/fail table plus failure examples
//   Add --smart to parse with smart punctuation on (swift-markdown's default).

var keepBOM = false

func decode(_ data: Data) -> String? {
    var bytes = [UInt8](data)
    if !keepBOM, bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) } // Spike 2: strip and remember
    if keepBOM { return String(decoding: bytes, as: UTF8.self) } // keeps U+FEFF; lossy, test only
    return String(data: Data(bytes), encoding: .utf8)
}

func typeName(_ node: Markup) -> String {
    String(reflecting: type(of: node)).replacingOccurrences(of: "Markdown.", with: "")
}

struct Finding {
    let file: String
    let type: String
    let location: String
    let slice: String
    let problem: String
}

final class Checker {
    var total: [String: Int] = [:]
    var failed: [String: Int] = [:]
    var deviated: [String: Int] = [:]
    var findings: [Finding] = []
    var deviations: [Finding] = []

    func check(file: String, text: String, smart: Bool) {
        let index = LineIndex(text)
        let document = Document(parsing: text, options: smart ? [] : [.disableSmartOpts])
        visit(document, parentRange: 0..<index.utf8.count, file: file, index: index)
    }

    private func visit(_ node: Markup, parentRange: Range<Int>, file: String, index: LineIndex) {
        let type = typeName(node)
        var ownRange = parentRange
        if !(node is Document) {
            total[type, default: 0] += 1
            var problems: [String] = []
            var sliceText = ""
            var location = "?"
            if let range = node.range {
                location = "\(range.lowerBound.line):\(range.lowerBound.column)-\(range.upperBound.line):\(range.upperBound.column)"
                if let r = index.utf8Range(range) {
                    ownRange = r
                    sliceText = index.slice(r)
                    if index.utf16Offset(r.lowerBound) == nil || index.utf16Offset(r.upperBound) == nil {
                        problems.append("range splits a multi-byte character")
                    }
                    if !parentRange.contains(r.lowerBound) && r.lowerBound != parentRange.upperBound || r.upperBound > parentRange.upperBound {
                        problems.append("outside parent range")
                    }
                    if let reason = expectation(for: node, slice: sliceText) { problems.append(reason) }
                } else {
                    problems.append("range out of bounds")
                }
            } else if node is Table.Cell, (node as! Table.Cell).childCount == 0 {
                problems.append("~ no range (padding cell for a short row; not in the source)")
            } else if node is SoftBreak || node is LineBreak {
                problems.append("~ no range (cmark doesn't track breaks; derive from neighbours)")
            } else {
                problems.append("no range")
            }
            if !problems.isEmpty && problems.allSatisfy({ $0.hasPrefix("~") }) {
                deviated[type, default: 0] += 1
                deviations.append(Finding(file: file, type: type, location: location, slice: sliceText, problem: problems.joined(separator: "; ")))
            } else if !problems.isEmpty {
                failed[type, default: 0] += 1
                findings.append(Finding(file: file, type: type, location: location, slice: sliceText, problem: problems.joined(separator: "; ")))
            }
        }
        // Siblings must be in order and must not overlap.
        var previousEnd = ownRange.lowerBound
        for child in node.children {
            if let range = child.range, let r = index.utf8Range(range) {
                if r.lowerBound < previousEnd {
                    findings.append(Finding(file: file, type: typeName(child), location: "\(range.lowerBound.line):\(range.lowerBound.column)",
                                            slice: index.slice(r), problem: "overlaps previous sibling"))
                    failed[typeName(child), default: 0] += 1
                }
                previousEnd = r.upperBound
            }
            visit(child, parentRange: ownRange, file: file, index: index)
        }
    }

    func report() {
        print("| Node type | Count | Exact | Known deviation | Wrong |")
        print("|---|---|---|---|---|")
        for type in total.keys.sorted() {
            let n = total[type]!, f = failed[type] ?? 0, d = deviated[type] ?? 0
            print("| \(type) | \(n) | \(n - f - d) | \(d) | \(f) |")
        }
        let deviationKinds = Dictionary(grouping: deviations) { "\($0.type): \($0.problem)" }
        if !deviationKinds.isEmpty {
            print("\n| Known deviation | Count |")
            print("|---|---|")
            for (kind, items) in deviationKinds.sorted(by: { $0.value.count > $1.value.count }) { print("| \(kind) | \(items.count) |") }
        }
        if findings.isEmpty { print("\nNo failures."); return }
        // Group by node type and the problem with its specifics stripped.
        func category(_ f: Finding) -> String {
            let generic = f.problem.replacingOccurrences(of: #""([^"\\]|\\.)*""#, with: "…", options: .regularExpression)
            return "\(f.type): \(generic)"
        }
        let groups = Dictionary(grouping: findings, by: category)
        print("\n| Failure kind | Count | Files | Example (file, range, slice) |")
        print("|---|---|---|---|")
        for (kind, items) in groups.sorted(by: { $0.value.count > $1.value.count }) {
            let files = Set(items.map(\.file)).count
            let e = items[0]
            let slice = e.slice.count > 40 ? String(e.slice.prefix(40)) + "…" : e.slice
            print("| \(kind.replacingOccurrences(of: "|", with: "\\|")) | \(items.count) | \(files) | \(e.file) \(e.location) `\(slice.debugDescription.replacingOccurrences(of: "|", with: "\\|"))` — \(e.problem.replacingOccurrences(of: "|", with: "\\|").prefix(80)) |")
        }
    }
}

func dump(_ path: String, smart: Bool) {
    guard let data = FileManager.default.contents(atPath: path), let text = decode(data) else { print("can't read \(path)"); return }
    let index = LineIndex(text)
    func walk(_ node: Markup, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        if let range = node.range, let r = index.utf8Range(range) {
            let u16 = "\(index.utf16Offset(r.lowerBound).map(String.init) ?? "?")..<\(index.utf16Offset(r.upperBound).map(String.init) ?? "?")"
            print("\(indent)\(typeName(node)) \(range.lowerBound.line):\(range.lowerBound.column)-\(range.upperBound.line):\(range.upperBound.column) utf8 \(r) utf16 \(u16) \(index.slice(r).debugDescription)")
        } else {
            print("\(indent)\(typeName(node)) <no range>")
        }
        for child in node.children { walk(child, depth: depth + 1) }
    }
    walk(Document(parsing: text, options: smart ? [] : [.disableSmartOpts]), depth: 0)
}

var args = Array(CommandLine.arguments.dropFirst())
let smart = args.contains("--smart")
keepBOM = args.contains("--keep-bom")
args.removeAll { $0 == "--smart" || $0 == "--keep-bom" }
switch args.first {
case "dump":
    for path in args.dropFirst() { dump(path, smart: smart) }
case "check":
    let checker = Checker()
    var skipped: [String] = []
    for path in args.dropFirst() {
        guard let data = FileManager.default.contents(atPath: path), let text = decode(data) else { skipped.append(path); continue }
        checker.check(file: URL(fileURLWithPath: path).lastPathComponent, text: text, smart: smart)
    }
    checker.report()
    if !skipped.isEmpty { print("\nSkipped (not UTF-8): \(skipped.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))") }
default:
    print("usage: spike1-ranges dump|check [--smart] <file>...")
    exit(2)
}
