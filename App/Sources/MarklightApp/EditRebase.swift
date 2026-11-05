import MarklightCore

/// An outstanding edit still targets the original characters. Insertions at
/// its lower boundary precede it, and insertions at the upper boundary follow
/// it. Overlap means the intent cannot safely be applied to this snapshot.
func rebaseEdit(_ target: Range<Int>, over change: Patch, deletingAtCaret: Bool = false) -> Range<Int>? {
    let range = change.range
    if range.isEmpty && change.replacement.isEmpty { return target }
    if target.isEmpty {
        let at = target.lowerBound
        if deletingAtCaret && range.lowerBound <= at && at <= range.upperBound { return nil }
        if range.lowerBound < at && at < range.upperBound { return nil }
    } else if range.isEmpty {
        if target.lowerBound < range.lowerBound && range.lowerBound < target.upperBound { return nil }
        if range.lowerBound == target.upperBound { return target }
    } else if range.overlaps(target) {
        return nil
    }
    return change.transform(target.lowerBound)..<change.transform(target.upperBound)
}
