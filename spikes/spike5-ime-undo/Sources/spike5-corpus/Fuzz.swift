import EditCore
import Foundation

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Random edits on real documents, judged by checks independent of the editor's
/// own verification.
struct Fuzzer {
    var rng: SplitMix
    var counts: [String: (ok: Int, noop: Int, refused: Int)] = [:]
    var refusals: [String: Int] = [:]
    var violations: [String: Int] = [:]
    var examples: [String] = []
    var refusedExamples: [String] = []
    var times: [Double] = []

    mutating func violation(_ kind: String, _ file: String, _ op: String, _ before: [UInt16], _ after: [UInt16], _ patch: Patch?) {
        violations[kind, default: 0] += 1
        guard examples.count < 40 else { return }
        var ctx = "?"
        if let p = patch {
            let lo = max(0, p.range.lowerBound - 40), hi = min(before.count, p.range.upperBound + 40)
            ctx = String(decoding: before[lo..<hi], as: UTF16.self).debugDescription + " -> " + String(decoding: after[max(0, p.range.lowerBound - 40)..<min(after.count, p.range.lowerBound + p.replacement.count + 40)], as: UTF16.self).debugDescription
        }
        examples.append("[\(kind)] \(file) \(op): \(ctx)")
    }

    func words(_ doc: DocModel) -> String {
        doc.root.allLeaves().map { Editor.plainText($0) }.joined().filter { !$0.isWhitespace }
    }

    /// Top-level blocks wholly before or after the patch must parse the same.
    func outsideChanged(_ old: DocModel, _ new: DocModel, _ patch: Patch) -> Bool {
        let a = old.root.children, b = new.root.children
        func separated(_ gap: Range<Int>) -> Bool {
            let text = old.units[gap]
            let newlines = text.filter { $0 == 0x0A || $0 == 0x0D }.count
            return newlines >= 2 || text.contains { $0 != 0x0A && $0 != 0x0D && $0 != 0x20 && $0 != 0x09 }
        }
        let before = a.prefix { $0.range.upperBound < patch.range.lowerBound && separated($0.range.upperBound..<patch.range.lowerBound) }
        for (i, block) in before.enumerated() {
            guard i < b.count, Outline.of(single: block) == Outline.of(single: b[i]) else { return true }
        }
        let after = a.reversed().prefix { $0.range.lowerBound > patch.range.upperBound && separated(patch.range.upperBound..<$0.range.lowerBound) }
        for (i, block) in after.enumerated() {
            guard i < b.count, Outline.of(single: block) == Outline.of(single: b[b.count - 1 - i]) else { return true }
        }
        return false
    }

    mutating func run(file: String, text: String, ops: Int) {
        let editor = Editor(text: text)
        let original = editor.units
        var done = 0
        let inserts = ["x", " ", "*", "_", "`", "[", "]", "#", "|", "<", "&", "\\", "中", "🎉", "~", "-", ">", "1."]
        for _ in 0..<ops {
            let leaves = editor.doc.root.allLeaves().filter { !$0.opaque && $0.atoms.contains { $0.range != nil } }
            guard let leaf = leaves.randomElement(using: &rng) else { break }
            // Never inside a surrogate pair: the range contract forbids it.
            let offsets = leaf.atoms.filter { !(0xDC00..<0xE000).contains($0.unit) }.compactMap { $0.range?.lowerBound }
                + [leaf.atoms.last?.range?.upperBound ?? leaf.content.upperBound]
            let o = offsets.randomElement(using: &rng)!
            let o2 = offsets.randomElement(using: &rng)!
            let span = min(o, o2)..<max(o, o2)
            let first = offsets[0]
            var name: String
            var command: Command
            var conserves = false
            switch Int.random(in: 0..<12, using: &rng) {
            case 0:
                name = "insert a letter"
                command = .insert("x", o..<o)
            case 1, 2:
                name = "insert"
                command = .insert(inserts.randomElement(using: &rng)!, o..<o)
            case 3:
                name = "backspace"
                command = .delete(o..<o, backward: true)
            case 4:
                name = "delete range"
                command = .delete(span, backward: true)
            case 5:
                name = "enter"
                command = .enter(o..<o)
                conserves = true
            case 6:
                name = "backspace at block start"
                command = .delete(first..<first, backward: true)
                conserves = true
            case 7:
                name = "toggle mark"
                command = .toggle([MarkKind.strong, .em, .code, .strike].randomElement(using: &rng)!, span)
            case 8:
                name = "heading"
                command = .heading(Int.random(in: 0...3, using: &rng), at: o)
            case 9:
                name = "paste plain"
                command = .pastePlain(["a b", "x\ny", "p*q\n\nr_s"].randomElement(using: &rng)!, o..<o)
            case 10:
                name = "paste rich"
                command = .pasteRich([PasteBlock(.paragraph, [PasteRun("x", marks: ["strong"]), PasteRun(" y")])], o..<o)
            default:
                name = "delete across blocks"
                let later = leaves.filter { $0.content.lowerBound > leaf.content.upperBound }.prefix(3)
                guard let other = later.randomElement(using: &rng), let end = other.atoms.first?.range?.upperBound else { continue }
                command = .delete(o..<end, backward: true)
            }
            let before = editor.units
            let oldDoc = editor.doc
            if ProcessInfo.processInfo.environment["FUZZ_TRACE"] != nil {
                FileHandle.standardError.write(Data("\(file) \(name) \(command) in \(String(decoding: before, as: UTF16.self).debugDescription)\n".utf8))
            }
            let clock = ContinuousClock()
            var outcome: Outcome!
            let elapsed = clock.measure { outcome = editor.perform(command) }
            times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            var c = counts[name] ?? (0, 0, 0)
            switch outcome.path {
            case .refused:
                c.refused += 1
                if outcome.note.hasPrefix("no serialization"), name.hasPrefix("insert") || name == "backspace" || name == "delete range", refusedExamples.count < 30 {
                    let at = o
                    let lo = max(0, at - 30), hi = min(before.count, at + 30)
                    var insertedText = ""
                    if case .insert(let t, _) = command { insertedText = t }
                    refusedExamples.append("\(name) \(insertedText.debugDescription) at \(at - lo) in \(String(decoding: before[lo..<hi], as: UTF16.self).debugDescription)")
                }
                refusals[outcome.note.replacingOccurrences(of: #"\d+"#, with: "N", options: .regularExpression), default: 0] += 1
            case .noop: c.noop += 1
            default: c.ok += 1
            }
            counts[name] = c
            guard let patch = outcome.patch else {
                if editor.units != before { violation("changed without a patch", file, name, before, editor.units, nil) }
                continue
            }
            done += 1
            var rebuilt = before
            rebuilt.replaceSubrange(patch.range, with: patch.replacement)
            if rebuilt != editor.units { violation("patch doesn't reproduce result", file, name, before, editor.units, patch) }
            if outsideChanged(oldDoc, editor.doc, patch) { violation("a block outside the patch changed", file, name, before, editor.units, patch) }
            if conserves, words(oldDoc) != words(editor.doc) { violation("text lost or added", file, name, before, editor.units, patch) }
            let opaqueBefore = oldDoc.root.allLeaves().filter { $0.opaque }.count
            let opaqueAfter = editor.doc.root.allLeaves().filter { $0.opaque }.count
            if opaqueAfter > opaqueBefore { violation("a block became unanchorable", file, name, before, editor.units, patch) }
            for l in editor.doc.root.allLeaves() where !l.opaque {
                if case .code = l.kind { continue }
                if Serializer.write(l.atoms, source: editor.units) != Array(editor.units[l.content]) {
                    violation("round-trip broke after edit", file, name, before, editor.units, patch)
                    break
                }
            }
        }
        let result = editor.units
        while editor.canUndo { editor.undo() }
        if editor.units != original { violation("undo didn't restore bytes", file, "all", original, editor.units, nil) }
        while editor.canRedo { editor.redo() }
        if editor.units != result { violation("redo didn't restore bytes", file, "all", result, editor.units, nil) }
    }
}
