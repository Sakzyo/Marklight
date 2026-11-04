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
    var presented: (Int) -> Void = { _ in }

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
        if let p = pending { pending = patch.range.contains(p) ? nil : patch.transform(p) }
        localCaret = localCaret.map { patch.transform($0.lowerBound)..<patch.transform($0.upperBound) }
        schedule(immediate: patch.origin == .rendered)
    }

    /// Validate against the text the page saw before transforming. In particular
    /// an invalid old offset must not be made valid by clamping it into a deletion.
    func current(_ range: Range<Int>, at version: Int) -> Range<Int>? {
        guard version >= 0, version <= buffer.version, range.lowerBound >= 0 else { return nil }
        var carried = range
        if version != buffer.version {
            guard let first = changes.firstIndex(where: { $0.version == version + 1 }),
                  range.upperBound <= changes[first].oldLength else { return nil }
            for change in changes[first...] {
                let patch = change.patch
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

    func historyMoved(to range: Range<Int>) {
        localCaret = range
        // Markdown has no paragraph node for an empty physical line. Undoing
        // typing into one must restore the caret holder so the next key works.
        let i = range.lowerBound, u = buffer.units
        if range.isEmpty && (i == 0 || u[i - 1] == 10 || u[i - 1] == 13) &&
            (i == u.count || u[i] == 10 || u[i] == 13) {
            pending = i
        } else { pending = nil }
        schedule(immediate: true)
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
        if scheduled != nil && !immediate { return }
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scheduled = nil
            self?.update()
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : Self.delay), execute: work)
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
            let single = !load && cached != nil && history.count == 1 ? history[0] : nil
            let new = HTMLRenderer.render(doc, pending: pending, reusing: old, patch: single)
            let content: PreviewUpdate.Content
            if !load, let old { content = .patch(old.patch(to: new)) }
            else { content = .load(new.blocks) }
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
                            self.presented(version)
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
