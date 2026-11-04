import AppKit
import MarklightCore

enum SourceTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

    static func attributes(_ style: HighlightSpan.Style) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading: return [.foregroundColor: NSColor.controlAccentColor]
        case .syntax: return [.foregroundColor: NSColor.tertiaryLabelColor]
        case .strikethrough: return [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .code, .codeBlock: return [.foregroundColor: NSColor.systemTeal]
        case .link: return [.foregroundColor: NSColor.linkColor]
        case .url, .frontMatter: return [.foregroundColor: NSColor.secondaryLabelColor]
        case .image: return [.foregroundColor: NSColor.systemPurple]
        case .listMarker, .quoteMarker: return [.foregroundColor: NSColor.systemOrange]
        case .rule: return [.foregroundColor: NSColor.tertiaryLabelColor]
        case .html: return [.foregroundColor: NSColor.systemPink]
        case .escape: return [.foregroundColor: NSColor.systemBrown]
        case .invalidByte: return [.backgroundColor: NSColor.systemRed.withAlphaComponent(0.3)]
        case .strong, .emphasis: return [:]
        }
    }

    static func traits(_ style: HighlightSpan.Style) -> NSFontTraitMask? {
        switch style {
        case .heading, .strong: return .boldFontMask
        case .emphasis: return .italicFontMask
        default: return nil
        }
    }
}

/// Keeps the text storage's attributes matching a parse of the buffer. Parsing is
/// debounced and off the main thread, so typing never waits for it.
final class SourceHighlighter {
    private let buffer: Buffer
    private weak var textView: NSTextView?
    private let queue = DispatchQueue(label: "marklight.highlight", qos: .userInitiated)
    private var pending: DispatchWorkItem?
    private var shown: [HighlightSpan] = []
    private var shownLength = 0
    static let debounce = 0.06

    init(buffer: Buffer, textView: NSTextView) {
        self.buffer = buffer
        self.textView = textView
    }

    func scheduleUpdate() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.update() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SourceHighlighter.debounce, execute: work)
    }

    func update() {
        let units = buffer.units
        let version = buffer.version
        queue.async { [weak self] in
            let spans = Highlighter.spans(ParsedDocument(units: units))
            DispatchQueue.main.async {
                guard let self, self.buffer.version == version else { return } // a newer update is on its way
                self.show(spans, length: units.count)
            }
        }
    }

    /// Only touches what differs. Text edits already moved the attributes after
    /// them, so those spans compare equal once shifted.
    private func show(_ spans: [HighlightSpan], length: Int) {
        guard let storage = textView?.textStorage, storage.length == length else { return }
        let delta = length - shownLength
        var head = 0
        while head < shown.count, head < spans.count, shown[head] == spans[head] { head += 1 }
        var tail = 0
        while tail < shown.count - head, tail < spans.count - head {
            let old = shown[shown.count - 1 - tail], new = spans[spans.count - 1 - tail]
            guard old.style == new.style, old.range.lowerBound + delta == new.range.lowerBound,
                  old.range.upperBound + delta == new.range.upperBound else { break }
            tail += 1
        }
        let oldMiddle = shown[head..<(shown.count - tail)]
        let newMiddle = spans[head..<(spans.count - tail)]
        shown = spans
        shownLength = length
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else { return }
        // Nested spans can start earlier, so widen to the lines the change touches.
        let lo = Swift.min(oldMiddle.map(\.range.lowerBound).min() ?? length, newMiddle.map(\.range.lowerBound).min() ?? length)
        let hi = Swift.max((oldMiddle.map(\.range.upperBound).max() ?? 0) + delta, newMiddle.map(\.range.upperBound).max() ?? 0)
        let text = storage.string as NSString
        let region = text.lineRange(for: NSRange(location: Swift.min(lo, length), length: Swift.max(0, Swift.min(hi, length) - Swift.min(lo, length))))

        storage.beginEditing()
        storage.setAttributes(SourceTheme.base, range: region)
        for span in spans {
            let range = NSRange(span.range)
            let overlap = NSIntersectionRange(range, region)
            guard overlap.length > 0 else { continue }
            storage.addAttributes(SourceTheme.attributes(span.style), range: overlap)
            if let traits = SourceTheme.traits(span.style) { storage.applyFontTraits(traits, range: overlap) }
        }
        storage.endEditing()
    }
}
