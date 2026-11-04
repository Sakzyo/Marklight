import Foundation

public enum BufferError: Error, Equatable {
    case readOnly
    case rangeOutOfBounds
    case splitsSurrogatePair
}

/// The document buffer: the only copy of the truth.
///
/// Holds the exact text in UTF-16 units plus what's needed to write it back byte
/// for byte. Both panes change it only by applying `Patch` values, and it keeps
/// the single undo stack. See `docs/plan.md` sections 2.1 and 2.7.
public final class Buffer {
    public private(set) var units: [UInt16]
    public private(set) var format: FileFormat
    /// Bumped by every change. Panes use it to carry offsets across edits.
    public private(set) var version = 0

    /// The bytes on disk, and the text they decode to. While the text matches,
    /// saving writes these bytes back rather than re-encoding.
    private var savedData: Data
    private var savedUnits: [UInt16]

    private var observers: [UUID: (Patch) -> Void] = [:]

    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private var sealed = false

    /// A pause this long starts a new undo step.
    public static let undoPause = 1.0
    /// Replaceable so tests can control time.
    public var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    public init() {
        units = []
        format = .newDocument
        savedData = Data()
        savedUnits = []
    }

    public init(contentsOf data: Data) {
        let decoded = TextCodec.decode(data)
        units = decoded.units
        format = decoded.format
        savedData = data
        savedUnits = decoded.units
    }

    public var text: String { String(decoding: units, as: UTF16.self) }

    /// The file couldn't be decoded without loss, so it can't be edited.
    public var isReadOnly: Bool { format.encoding == .raw }

    /// Compares units rather than `String`s: `==` on `String` treats canonically
    /// equivalent text as equal, which would hide a real edit.
    public var isDirty: Bool { units != savedUnits }

    /// The bytes to write on save.
    public func serialized() -> Data {
        isDirty ? TextCodec.encode(units, format: format) : savedData
    }

    /// Call after a save succeeds, with the bytes that were written.
    public func markSaved(_ data: Data) {
        savedData = data
        savedUnits = units
    }

    /// Whether `data` is what this buffer last read or saved.
    public func matchesSavedFile(_ data: Data) -> Bool { data == savedData }

    /// Replaces everything with a new reading of the file. Undo history refers to
    /// text that's gone, so it's dropped.
    public func reload(contentsOf data: Data) {
        let decoded = TextCodec.decode(data)
        let patch = Patch.minimal(from: units, to: decoded.units, origin: .command)
        units = decoded.units
        format = decoded.format
        savedData = data
        savedUnits = decoded.units
        undoStack.removeAll()
        redoStack.removeAll()
        version += 1
        notify(patch)
    }

    // MARK: - Editing

    /// Applies an edit. `selectionBefore` is what undo restores; it defaults to the patch's range.
    public func apply(_ patch: Patch, selectionBefore: Range<Int>? = nil) throws {
        guard !isReadOnly else { throw BufferError.readOnly }
        guard patch.range.lowerBound >= 0, patch.range.upperBound <= units.count else { throw BufferError.rangeOutOfBounds }
        guard !splitsPair(at: patch.range.lowerBound), !splitsPair(at: patch.range.upperBound) else {
            throw BufferError.splitsSurrogatePair
        }
        let inverse = Patch(range: patch.range.lowerBound..<(patch.range.lowerBound + patch.replacement.count),
                            replacement: Array(units[patch.range]), origin: .command)
        units.replaceSubrange(patch.range, with: patch.replacement)
        remember(patch, inverse: inverse, selection: selectionBefore ?? patch.range)
        version += 1
        notify(patch)
    }

    private func splitsPair(at offset: Int) -> Bool {
        guard offset > 0, offset < units.count else { return false }
        return (0xD800..<0xDC00).contains(units[offset - 1]) && (0xDC00..<0xE000).contains(units[offset])
    }

    /// The line ending new text should use at `offset`: the nearest one, so a
    /// mixed file stays as it is around the edit.
    public func lineEnding(at offset: Int) -> [UInt16] {
        var i = min(offset, units.count) - 1
        while i >= 0 {
            if units[i] == 0x0A { return i > 0 && units[i - 1] == 0x0D ? [0x0D, 0x0A] : [0x0A] }
            if units[i] == 0x0D { return [0x0D] }
            i -= 1
        }
        i = max(0, offset)
        while i < units.count {
            if units[i] == 0x0D { return i + 1 < units.count && units[i + 1] == 0x0A ? [0x0D, 0x0A] : [0x0D] }
            if units[i] == 0x0A { return [0x0A] }
            i += 1
        }
        return [0x0A]
    }

    // MARK: - Observing

    /// Calls `handler` after every change, until the token is passed to `removeObserver`.
    @discardableResult
    public func addObserver(_ handler: @escaping (Patch) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func notify(_ patch: Patch) {
        for observer in observers.values { observer(patch) }
    }

    // MARK: - Undo

    /// Everything between two presses of Cmd-Z.
    private struct Step {
        enum Kind { case typing, deleting, other }
        var kind: Kind
        var forward: [Patch]
        var inverse: [Patch]
        var selectionBefore: Range<Int>
        var caretAfter: Int
        var lastEdit: Double
        var endsInSpace: Bool
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Ends the current undo step, so the next edit starts a new one.
    public func sealUndoStep() { sealed = true }

    /// Typing and Backspace run together until a pause, a jump, or a new word.
    /// Everything else is a step of its own.
    private func remember(_ patch: Patch, inverse: Patch, selection: Range<Int>) {
        redoStack.removeAll()
        let isInsert = patch.range.isEmpty && !patch.replacement.isEmpty
        let isShortDelete = patch.replacement.isEmpty && patch.range.count <= 2
        let kind: Step.Kind = isInsert ? .typing : isShortDelete ? .deleting : .other
        // Backspace removes text before the caret, so the run continues from there.
        let start = kind == .deleting ? patch.range.upperBound : patch.range.lowerBound
        let caret = patch.range.lowerBound + patch.replacement.count
        let lastUnit = patch.replacement.last.flatMap(Unicode.Scalar.init)
        let endsInSpace = lastUnit?.properties.isWhitespace ?? false
        let now = clock()
        if !sealed, let last = undoStack.last, last.kind == kind, kind != .other, now - last.lastEdit < Buffer.undoPause,
           start == last.caretAfter, !(kind == .typing && last.endsInSpace && !endsInSpace) {
            var step = undoStack.removeLast()
            step.forward.append(patch)
            step.inverse.append(inverse)
            step.caretAfter = caret
            step.lastEdit = now
            step.endsInSpace = endsInSpace
            undoStack.append(step)
            return
        }
        sealed = false
        undoStack.append(Step(kind: kind, forward: [patch], inverse: [inverse], selectionBefore: selection,
                              caretAfter: caret, lastEdit: now, endsInSpace: endsInSpace))
    }

    /// Undoes one step, returning the change and where the selection goes.
    @discardableResult
    public func undo() -> (patch: Patch, selection: Range<Int>)? {
        guard let step = undoStack.popLast() else { return nil }
        let before = units
        for patch in step.inverse.reversed() { units.replaceSubrange(patch.range, with: patch.replacement) }
        redoStack.append(step)
        return finishHistoryMove(from: before, selection: step.selectionBefore)
    }

    @discardableResult
    public func redo() -> (patch: Patch, selection: Range<Int>)? {
        guard let step = redoStack.popLast() else { return nil }
        let before = units
        for patch in step.forward { units.replaceSubrange(patch.range, with: patch.replacement) }
        undoStack.append(step)
        return finishHistoryMove(from: before, selection: step.caretAfter..<step.caretAfter)
    }

    private func finishHistoryMove(from before: [UInt16], selection: Range<Int>) -> (patch: Patch, selection: Range<Int>) {
        sealed = true
        version += 1
        let patch = Patch.minimal(from: before, to: units, origin: .command)
        notify(patch)
        return (patch, selection)
    }
}
