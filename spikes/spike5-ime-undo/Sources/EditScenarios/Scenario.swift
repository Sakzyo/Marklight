import Foundation
import EditCore

public enum Action {
    case type(String)               // one command per Character, as keystrokes arrive
    case backspace, forwardDelete, enter, shiftEnter
    case deleteSelection            // what the browser's target range gives for word and line deletes
    case toggle(MarkKind)
    case heading(Int)
    case checkbox
    case pastePlain(String)
    case pasteRich([PasteBlock])
}

public struct Scenario: Sendable {
    public let name: String
    public let before: String
    public let actions: [Action]
    public let after: String
    public let outline: String

    init(_ name: String, _ before: String, _ actions: [Action], _ after: String, _ outline: String) {
        self.name = name
        self.before = before
        self.actions = actions
        self.after = after
        self.outline = outline
    }
}

extension Action: @unchecked Sendable {}

/// `‸` is the caret; `⟦ ⟧` is a selection. Both are in source coordinates.
public func parseMarkers(_ marked: String) -> (text: String, selection: Range<Int>) {
    var out: [UInt16] = []
    var lo = 0, hi: Int?
    for scalar in marked.unicodeScalars {
        switch scalar {
        case "‸": lo = out.count; hi = out.count
        case "⟦": lo = out.count
        case "⟧": hi = out.count
        default: out += Array(String(scalar).utf16)
        }
    }
    return (String(decoding: out, as: UTF16.self), lo..<(hi ?? lo))
}

public func apply(_ action: Action, _ editor: Editor, _ selection: inout Range<Int>, _ snapshots: inout [String]) {
    func go(_ c: Command) {
        let o = editor.perform(c)
        selection = o.caret..<o.caret
        if editor.text != snapshots.last { snapshots.append(editor.text) }
    }
    switch action {
    case .type(let text):
        for ch in text { go(.insert(String(ch), selection)) }
    case .backspace: go(.delete(selection, backward: true))
    case .forwardDelete: go(.delete(selection, backward: false))
    case .deleteSelection: go(.delete(selection, backward: true))
    case .enter: go(.enter(selection))
    case .shiftEnter: go(.lineBreak(selection))
    case .toggle(let k): go(.toggle(k, selection))
    case .heading(let n): go(.heading(n, at: selection.lowerBound))
    case .checkbox: go(.checkbox(at: selection.lowerBound))
    case .pastePlain(let t): go(.pastePlain(t, selection))
    case .pasteRich(let b): go(.pasteRich(b, selection))
    }
}

public let allScenarios: [Scenario] = typing + deleting + enter + lists + quotes + formatting + headings + pasting + tables + preservation + spike1Bugs + codeBlocks + fuzzFound + emptyLines
