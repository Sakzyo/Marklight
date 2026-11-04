import Foundation
import MarklightCore

/// One change for the page: a whole document, or the blocks that differ.
struct PreviewUpdate {
    enum Content {
        case load([RenderedBlock])
        case patch(BlockPatch)
    }

    let content: Content
    let version: Int
    let hasRemoteImages: Bool
    let caret: Range<Int>?
    let edits: [[Int]]
}

final class PreviewUpdater {
    static let delay = 0.04
    private let buffer: Buffer
    private let queue = DispatchQueue(label: "marklight.preview", qos: .userInitiated)
    private var observer: UUID?
    private var parsed: (version: Int, document: IncrementalDocument)?
    private var shown: RenderedDocument?
    private var changes: [(version: Int, patch: Patch, oldLength: Int)] = []
    private var localCaret: Range<Int>?
    private(set) var pending: Int?
    private var pendingHistory = PendingCaretHistory()
    private var movingHistory = false
    private var idleCheck: DispatchWorkItem?
    private var scheduled: DispatchWorkItem?
    private var isPaused = true
    private var isPageReady = false
    private var isUpdating = false
    private var needsLoad = true
    private var generation = 0
    private(set) var shownVersion: Int?

    var present: (PreviewUpdate, @escaping (Bool) -> Void) -> Void = { _, done in done(true) }
    var caughtUp: () -> Void = {}

    init(buffer: Buffer) {
        self.buffer = buffer
        observer = buffer.addObserver { [weak self] patch in self?.changed(patch) }
    }

    deinit {
        if let observer { buffer.removeObserver(observer) }
        idleCheck?.cancel()
    }

    private func changed(_ patch: Patch) {
        idleCheck?.cancel()
        let oldLength = buffer.units.count - patch.replacement.count + patch.range.count
        changes.append((buffer.version, patch, oldLength))
        if changes.count > 512 { changes.removeFirst() }
        parsed = nil
        if !movingHistory {
            if !buffer.canUndo && !buffer.canRedo { // reload discarded the buffer's history
                pendingHistory = PendingCaretHistory()
                pending = nil
            } else {
                let before = pending
                if let p = pending {
                    let replaced = patch.range.contains(p) || (patch.range.lowerBound == p && !patch.replacement.isEmpty)
                    pending = replaced ? nil : patch.transform(p)
                }
                pendingHistory.record(patch, before: before, after: pending)
            }
        }
        localCaret = localCaret.map { patch.transform($0.lowerBound)..<patch.transform($0.upperBound) }
        schedule() // accepted() supplies the verified snapshot after all buffer observers return
    }

    /// Validate against the text the page saw before transforming. In particular
    /// an invalid old offset must not be made valid by clamping it into a deletion.
    func current(_ range: Range<Int>, at version: Int, inputType: String? = nil) -> Range<Int>? {
        guard version >= 0, version <= buffer.version, range.lowerBound >= 0 else { return nil }
        var carried = range
        if version != buffer.version {
            guard let first = changes.firstIndex(where: { $0.version == version + 1 }),
                  range.upperBound <= changes[first].oldLength else { return nil }
            for change in changes[first...] {
                let patch = change.patch
                if let inputType {
                    guard let next = rebaseEdit(carried, over: patch, deletingAtCaret: inputType.hasPrefix("delete")) else { return nil }
                    carried = next
                    continue
                }
                // The original text at an endpoint disappeared. A queued input
                // can no longer prove which character the user meant.
                for end in [carried.lowerBound, carried.upperBound]
                    where end > patch.range.lowerBound && end < patch.range.upperBound { return nil }
                carried = patch.transform(carried.lowerBound)..<patch.transform(carried.upperBound)
            }
        }
        guard carried.upperBound <= buffer.units.count else { return nil }
        for end in [carried.lowerBound, carried.upperBound] where end < buffer.units.count {
            if (0xDC00..<0xE000).contains(buffer.units[end]) { return nil }
        }
        return carried
    }

    /// Verify on a snapshot. The caller checks the version before committing.
    func verify(inputType: String, data: String?, selection: Range<Int>, target: Range<Int>?,
                completion: @escaping (Int, RenderedEdit?) -> Void) {
        let version = buffer.version, units = buffer.units, pending = self.pending
        let cached = parsed?.version == version ? parsed?.document : nil
        queue.async {
            let doc = cached ?? IncrementalDocument(units: units)
            let edit = BlockSerializer.edit(doc, inputType: inputType, data: data, selection: selection, target: target, pending: pending)
            DispatchQueue.main.async { completion(version, edit) }
        }
    }

    /// The buffer's synchronous observer has already recorded this patch.
    func accepted(_ edit: RenderedEdit) {
        let version = buffer.version
        parsed = (version, edit.document)
        pendingHistory.confirm(edit.patch, after: edit.pending)
        pending = edit.pending
        localCaret = edit.caret..<edit.caret
        schedule(immediate: true)
        guard !edit.document.usedFullParse else { return }
        let snapshot = edit.document
        let check = DispatchWorkItem { [weak self] in
            let full = IncrementalDocument(units: snapshot.units)
            guard !snapshot.agrees(with: full) else { return }
            DispatchQueue.main.async {
                guard let self, self.buffer.version == version else { return }
                NSLog("Marklight: incremental parse disagreed with full parse at version %d; restoring full render", version)
                self.parsed = (version, full)
                self.needsLoad = true
                self.schedule(immediate: true)
            }
        }
        idleCheck = check
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: check)
    }

    /// Both responders use Buffer's one history stack. The pending paragraph
    /// has no Markdown node, so restore its recorded position with that step.
    func moveHistory(redo: Bool, fromPreview: Bool) -> (patch: Patch, selection: Range<Int>)? {
        movingHistory = true
        let result = redo ? buffer.redo() : buffer.undo()
        movingHistory = false
        guard let result else { return nil }
        pending = pendingHistory.move(redo: redo, patch: result.patch)
        if fromPreview { localCaret = result.selection }
        schedule(immediate: fromPreview || pending != nil)
        return result
    }

    var isCurrent: Bool { isPageReady && !needsLoad && !isUpdating && shownVersion == buffer.version }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        schedule()
    }

    func pageWillLoad() {
        generation += 1
        isPageReady = false
        needsLoad = true
        localCaret = nil
    }

    func pageReady() {
        isPageReady = true
        needsLoad = true
        schedule()
    }

    private var canUpdate: Bool { !isPaused && isPageReady && !isUpdating && !isCurrent }

    private func schedule(immediate: Bool = false) {
        guard canUpdate else { return }
        if immediate {
            scheduled?.cancel()
            scheduled = nil
            update()
            return
        }
        guard scheduled == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.scheduled = nil
            self?.update()
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    private func update() {
        guard canUpdate else { return }
        isUpdating = true
        let version = buffer.version, generation = self.generation, units = buffer.units
        let cached = parsed?.version == version ? parsed?.document : nil
        let pending = self.pending, caret = localCaret, old = shown
        let previousVersion = shownVersion ?? -1
        let history = changes.filter { $0.version > previousVersion }.map(\.patch)
        let load = needsLoad || old == nil || history.count != version - previousVersion
        localCaret = nil
        needsLoad = false
        queue.async { [weak self] in
            let doc = cached ?? IncrementalDocument(units: units)
            let new: RenderedDocument
            let content: PreviewUpdate.Content
            if !load, let old, cached != nil, history.count == 1 {
                let update = HTMLRenderer.update(old, to: doc, after: history[0], pending: pending)
                new = update.document
                content = .patch(update.patch)
            } else {
                new = HTMLRenderer.render(doc, pending: pending)
                if !load, let old { content = .patch(old.patch(to: new)) }
                else { content = .load(new.blocks) }
            }
            let update = PreviewUpdate(content: content, version: version, hasRemoteImages: new.hasRemoteImages,
                                       caret: caret, edits: history.map { [$0.range.lowerBound, $0.range.upperBound, $0.replacement.count] })
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.generation == generation else { return self.finished() }
                if self.buffer.version == version { self.parsed = (version, doc) }
                self.present(update) { [weak self] success in
                    guard let self else { return }
                    if generation == self.generation {
                        if success {
                            self.shown = new
                            self.shownVersion = version
                        } else { self.needsLoad = true }
                    }
                    self.finished()
                }
            }
        }
    }

    private func finished() {
        isUpdating = false
        if isCurrent { caughtUp() } else { schedule(immediate: localCaret != nil) }
    }
}

/// Stores only caret positions and lengths, starting at the first pending
/// paragraph. The Buffer performs the undo and tells us the net change. Its
/// grouped inserts only grow, and grouped deletes only shrink, so their total
/// identifies how many component edits the step traversed. Edits creating or
/// consuming a pending paragraph are sealed on both sides.
private struct PendingCaretHistory {
    private struct Change {
        let delta: Int
        let before: Int?
        var after: Int?
    }

    private var changes: [Change] = []
    private var cursor = 0
    private var olderRedoSteps = 0

    mutating func record(_ patch: Patch, before: Int?, after: Int?) {
        changes.removeSubrange(cursor...)
        olderRedoSteps = 0
        guard !changes.isEmpty || before != nil || after != nil else { return }
        changes.append(Change(delta: patch.replacement.count - patch.range.count, before: before, after: after))
        cursor += 1
    }

    /// The synchronous observer recorded a provisional position, before Swift
    /// received the serializer's authoritative result for this rendered edit.
    mutating func confirm(_ patch: Patch, after: Int?) {
        if cursor > 0 {
            changes[cursor - 1].after = after
        } else if after != nil {
            record(patch, before: nil, after: after)
        }
    }

    mutating func move(redo: Bool, patch: Patch) -> Int? {
        guard !changes.isEmpty else { return nil }
        if !redo && cursor == 0 { olderRedoSteps += 1; return nil }
        if redo && olderRedoSteps > 0 { olderRedoSteps -= 1; return nil }
        let total = patch.replacement.count - patch.range.count
        var delta = 0, position: Int?
        repeat {
            guard redo ? cursor < changes.count : cursor > 0 else { break }
            if !redo { cursor -= 1 }
            let change = changes[cursor]
            position = redo ? change.after : change.before
            delta += redo ? change.delta : -change.delta
            if redo { cursor += 1 }
        } while total != delta
        return position
    }
}
