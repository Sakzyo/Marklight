import Foundation

/// An inline mark on a run of atoms. `open` and `close` are the exact source
/// text of its delimiters, so unchanged marks serialize to the same bytes.
public struct Mark: Hashable {
    public enum Kind: Hashable {
        case strong, em, strike, code
        case link(String)

        var name: String {
            switch self {
            case .strong: return "b"
            case .em: return "i"
            case .strike: return "s"
            case .code: return "c"
            case .link: return "a"
            }
        }
    }

    public let kind: Kind
    public let id: Int
    public let open: [UInt16]
    public let close: [UInt16]
    /// For `[shortcut]` and `[collapsed][]` links: what keeps the target when the
    /// text, which doubles as the lookup label, changes.
    public var explicitClose: [UInt16]? = nil

    /// Marks made by an edit, rather than parsed, have ids from here up.
    static let firstNewID = 1_000_000

    public static func == (a: Mark, b: Mark) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One rendered unit. Text atoms are single UTF-16 units, so DOM offsets line up
/// with atom indexes. `range` is where the atom came from; a new atom has none.
public struct Atom {
    public enum Kind: Equatable {
        case text
        case softBreak
        case hardBreak
        /// Image or inline HTML: one indivisible unit.
        case object
        /// Whitespace the parser ignores (trailing spaces, for example).
        case ignored
    }

    public var kind: Kind
    public var unit: UInt16
    public var marks: [Mark]
    public var range: Range<Int>?

    public init(kind: Kind, unit: UInt16 = 0, marks: [Mark] = [], range: Range<Int>? = nil) {
        self.kind = kind
        self.unit = unit
        self.marks = marks
        self.range = range
    }

    var isSpace: Bool {
        switch kind {
        case .softBreak, .hardBreak, .ignored: return true
        case .text: return unit == 0x20 || unit == 0x09 || unit == 0xA0
        case .object: return false
        }
    }
}

/// Inline structure used for rendering. `atoms` indexes the leaf's atom array.
public final class Inline {
    public enum Kind {
        case run
        case mark(Mark)
        case image(src: String, alt: String)
        case html(String)
    }

    public let kind: Kind
    public var range: Range<Int>
    public var atoms: Range<Int>
    public var children: [Inline] = []

    init(kind: Kind, range: Range<Int>, atoms: Range<Int>) {
        self.kind = kind
        self.range = range
        self.atoms = atoms
    }
}

public final class Block {
    public enum Kind: Equatable {
        case document, paragraph, heading(Int), quote
        case list(ordered: Bool, start: Int), item(checked: Bool?)
        case code(info: String), html, rule
        case table, row(header: Bool), cell
    }

    public let kind: Kind
    public var range: Range<Int>
    public var children: [Block] = []
    public weak var parent: Block?

    /// For leaves with inline content (paragraph, heading, cell).
    public var atoms: [Atom] = []
    public var inlines: [Inline] = []
    /// The source the atoms cover: what a re-serialized leaf replaces.
    public var content: Range<Int> = 0..<0
    /// The anchoring failed, so this leaf can't be edited in the rendered pane.
    public var opaque = false
    public var opaqueReason: String?

    init(kind: Kind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }

    public var isLeaf: Bool {
        switch kind {
        case .paragraph, .heading, .cell: return true
        default: return false
        }
    }

    public var isTextBlock: Bool {
        if case .code = kind { return true }
        return isLeaf
    }

    public var quoteDepth: Int {
        var depth = 0
        var b = parent
        while let block = b {
            if block.kind == .quote { depth += 1 }
            b = block.parent
        }
        return depth
    }

    public func allLeaves() -> [Block] {
        if isTextBlock { return [self] }
        return children.flatMap { $0.allLeaves() }
    }
}

extension UInt16 {
    static func of(_ c: Unicode.Scalar) -> UInt16 { UInt16(c.value) }
    var isASCIIPunctuation: Bool {
        (0x21...0x2F).contains(self) || (0x3A...0x40).contains(self) || (0x5B...0x60).contains(self) || (0x7B...0x7E).contains(self)
    }
    var isLineBreak: Bool { self == 0x0A || self == 0x0D }
    var isSpaceOrTab: Bool { self == 0x20 || self == 0x09 }
}

/// Maps swift-markdown's (line, UTF-8 column) to UTF-16 offsets.
struct LineMap {
    let units: [UInt16]
    private(set) var starts: [Int] = [0]

    init(_ units: [UInt16]) {
        self.units = units
        var i = 0
        while i < units.count {
            if units[i] == 0x0D {
                if i + 1 < units.count, units[i + 1] == 0x0A { i += 1 }
                starts.append(i + 1)
            } else if units[i] == 0x0A {
                starts.append(i + 1)
            }
            i += 1
        }
    }

    func offset(line: Int, column: Int) -> Int {
        guard line >= 1, line <= starts.count else { return units.count }
        var i = starts[line - 1]
        var bytes = column - 1
        while bytes > 0, i < units.count {
            let u = units[i]
            if u < 0x80 { bytes -= 1; i += 1 }
            else if u < 0x800 { bytes -= 2; i += 1 }
            else if u >= 0xD800, u < 0xDC00 { bytes -= 4; i += 2 }
            else { bytes -= 3; i += 1 }
        }
        return min(i, units.count)
    }
}
