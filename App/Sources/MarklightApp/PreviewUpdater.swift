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
}

/// Keeps the page following the buffer. Parsing, rendering, and diffing run on a
/// queue of their own, so typing never waits for them, and one update is in flight
/// at a time. Edits that arrive meanwhile are picked up together by the next one.
final class PreviewUpdater {
    /// A short wait, so a burst of keys is one update.
    static let delay = 0.04

    private let buffer: Buffer
    private let queue = DispatchQueue(label: "marklight.preview", qos: .userInitiated)
    private var observer: UUID?
    /// What the page shows. Only touched on `queue`.
    private var shown: RenderedDocument?

    private var isPaused = true
    /// Updates wait for this. A call into a page that's still navigating can
    /// report success without having run.
    private var isPageReady = false
    private var isScheduled = false
    private var isUpdating = false
    private var needsLoad = true
    private(set) var shownVersion: Int?

    /// Applies an update, then calls back with whether it worked.
    var present: (PreviewUpdate, @escaping (Bool) -> Void) -> Void = { _, done in done(true) }
    /// The page has reached the buffer's current version.
    var caughtUp: () -> Void = {}

    init(buffer: Buffer) {
        self.buffer = buffer
        observer = buffer.addObserver { [weak self] _ in self?.schedule() }
    }

    deinit {
        if let observer { buffer.removeObserver(observer) }
    }

    /// Whether the page shows the text in the buffer now.
    var isCurrent: Bool { isPageReady && !needsLoad && shownVersion == buffer.version }

    /// A hidden preview does no work. It catches up when it's shown again.
    func setPaused(_ paused: Bool) {
        isPaused = paused
        schedule()
    }

    func pageWillLoad() {
        isPageReady = false
        needsLoad = true
    }

    /// The page has loaded, and it's empty.
    func pageReady() {
        isPageReady = true
        needsLoad = true
        schedule()
    }

    private var canUpdate: Bool { !isPaused && isPageReady && !isUpdating && !isCurrent }

    private func schedule() {
        guard canUpdate, !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PreviewUpdater.delay) { [weak self] in
            guard let self else { return }
            isScheduled = false
            update()
        }
    }

    private func update() {
        guard canUpdate else { return }
        isUpdating = true
        let units = buffer.units
        let version = buffer.version
        let load = needsLoad
        needsLoad = false
        queue.async { [weak self] in
            guard let self else { return }
            let new = HTMLRenderer.render(ParsedDocument(units: units))
            let content: PreviewUpdate.Content
            if !load, let old = shown {
                content = .patch(old.patch(to: new))
            } else {
                content = .load(new.blocks)
            }
            shown = new
            let update = PreviewUpdate(content: content, version: version, hasRemoteImages: new.hasRemoteImages)
            DispatchQueue.main.async { [weak self] in
                self?.present(update) { [weak self] succeeded in self?.finished(version, succeeded: succeeded) }
            }
        }
    }

    private func finished(_ version: Int, succeeded: Bool) {
        isUpdating = false
        shownVersion = version
        if !succeeded { needsLoad = true } // the page and `shown` may disagree now
        if isCurrent { caughtUp() } else { schedule() }
    }
}
