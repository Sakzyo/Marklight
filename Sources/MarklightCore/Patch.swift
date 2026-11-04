/// Which pane made an edit. The originating pane never re-renders the region it
/// is editing. See `docs/contracts.md`.
public enum Origin: Sendable {
    case source
    case rendered
    case command
}

/// The single unit of change on the patch bus.
///
/// `range` is half-open, in UTF-16 code units into the decoded text before the
/// patch. An empty `replacement` deletes, and an empty range inserts.
public struct Patch: Equatable, Sendable {
    public let range: Range<Int>
    public let replacement: [UInt16]
    public let origin: Origin

    public init(range: Range<Int>, replacement: [UInt16], origin: Origin) {
        self.range = range
        self.replacement = replacement
        self.origin = origin
    }

    /// The smallest single replacement that turns `old` into `new`. It never
    /// splits a surrogate pair.
    public static func minimal(from old: [UInt16], to new: [UInt16], origin: Origin) -> Patch {
        func isLowSurrogate(_ unit: UInt16?) -> Bool { unit.map { (0xDC00..<0xE000).contains($0) } ?? false }
        var prefix = 0
        let limit = min(old.count, new.count)
        while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
        let oldNext = prefix < old.count ? old[prefix] : nil
        let newNext = prefix < new.count ? new[prefix] : nil
        if prefix > 0, isLowSurrogate(oldNext) || isLowSurrogate(newNext) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, isLowSurrogate(old[old.count - suffix]) { suffix -= 1 }
        return Patch(range: prefix..<(old.count - suffix), replacement: Array(new[prefix..<(new.count - suffix)]), origin: origin)
    }

    /// Carries an offset across this patch.
    public func transform(_ offset: Int) -> Int {
        if offset >= range.upperBound { return offset + replacement.count - range.count }
        if offset > range.lowerBound { return range.lowerBound + replacement.count }
        return offset
    }
}
