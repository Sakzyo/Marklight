import Foundation

/// The document buffer: the only copy of the truth.
///
/// Will own the exact document text plus the file details needed to write it
/// back byte-for-byte (encoding, BOM, line endings, trailing newline), apply
/// `Patch` values from either pane, keep the single undo stack, and notify
/// subscribers of changes. See `docs/plan.md` sections 2.1 and 2.7.
///
/// Placeholder: until Spike 2 settles the design, it holds the raw bytes and
/// returns them unchanged so the golden-file harness has something to run.
public struct Buffer {
    private let original: Data

    public init(contentsOf data: Data) {
        self.original = data
    }

    /// The bytes to write on save.
    public func serialized() -> Data {
        original
    }
}
