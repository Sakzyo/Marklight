# Decision log

Decisions made during brainstorming (2026-11-03). Add spike results at the bottom as they come in.

## Product

- Project name: Marklight. The first choice, Inkdown, was dropped because an existing Markdown editor uses that name. A Swift Markdown syntax-highlighter library called Marklight (macteo/Marklight) also exists, so the name-conflict check is still open (see `docs/plan.md`, section 5).
- Audience: developers writing READMEs, docs, and prompt files.
- Reader/editor balance: equal mix.
- Both the source view and the rendered view are fully editable and stay in sync.
- Rendered-pane editing covers typing, deleting, Enter/Backspace behavior, formatting shortcuts and toolbar, paste, task checkboxes, and table cells.
- Mermaid, math, and HTML blocks are edited in place: click to edit the block's source.
- Zero-diff save is a hard requirement.
- Single-document app for v1; no folder sidebar.
- Prompt-specific features deferred.
- Drag-reorder blocks and drag-drop images deferred.
- v1 render scope: headings, lists, code blocks, GFM tables, task lists, local images, Mermaid, math, HTML blocks.

## Technical

- Native `NSTextView` on TextKit 2 for the source pane.
- `WKWebView` with `contenteditable` for the rendered pane.
- Swift owns parsing, rendering, and serialization (`swift-markdown`).
- Patch bus: every edit becomes `Patch(range, replacement, origin)` on one buffer.
- One undo stack on the buffer.
- Prefer `beforeinput` interception over DOM diffing.
- Local files via a custom `WKURLSchemeHandler`.

## Distribution

- License: MIT.
- Minimum macOS: 14 (re-check before starting).
- Unsandboxed for v1.
- GitHub Releases, Sparkle in v1, unsigned builds at first.
- Get a Developer ID before 1.0 if possible.
- Homebrew: check current cask policy; personal tap as fallback.

## Contracts

- 2026-11-03, approved by the owner: `Patch` and `data-src` ranges are UTF-16 code units into the decoded text (Spike 1). Both panes produce UTF-16 offsets natively; only the parser adapter converts from swift-markdown's UTF-8 columns. Written down in `docs/contracts.md`.
- 2026-11-04, approved by the owner: the bridge messages and the `data-run`, `data-atomic`, `data-caret` and `data-raw` render attributes in `docs/bridge.md` (Spike 3).

## Go/no-go

- 2026-11-04, the owner's call after Spike 3: GO. Full rendered-pane editing stays in scope for v1.

## Proposed, awaiting approval

- Save strategy: resolve symlinks at open and use the resolved URL as the NSDocument `fileURL`; NSDocument safe save; in-place write when the file has more than one hard link (Spike 2).
- Remote images blocked by default, with a per-window "Load remote images" bar (Spike 6, open question 1).
- Local file access root: the git repository root when the document is inside one, otherwise the document's folder; serve the page at the document's matching path so `../` resolves as on disk (Spike 6, open question 2).
- `data-src` relative to the top-level block, with the block's offset held in JS (Spike 4). Changes an approved contract.
- Bridge: `v` and `targetV` on messages; `marklight.load`, `patch`, and `done` in place of `update` (Spike 4). Changes an approved contract.
- Bridge: an `undo` message, and `composed` and `range` on `input` (Spike 5). Changes an approved contract.
- Compare text by UTF-8 bytes, never `String ==`, which treats canonically equivalent text as equal (Spike 2).

## Known gaps for milestones

- M3: every edit re-parses the whole file (Spikes 3 and 4). Incremental parsing is required for large files.
- M3: editing must run off the main thread (Spike 4).
- M5: nothing in the rendered pane gets out of a code block at the end of a document (Spike 5 manual test). Needs a design.
- Before shipping: autosave or recovery, because a Swift trap can't be caught (Spike 3).

## Spike results

| Spike | Result | Fallback taken | Date |
|---|---|---|---|
| 1 Source ranges | Partial pass. Columns are UTF-8 byte offsets. Block ranges reliable; about 1.5% of inline ranges in real files are wrong for 6 known cmark-gfm reasons. See `spikes/spike1-ranges/REPORT.md` | Keep swift-markdown; add an inline re-anchoring pass in `Parser.swift`; always parse with `.disableSmartOpts` | 2026-11-03 |
| 2 Zero-diff I/O | Pass: 21/21 files byte-identical; mode, xattrs and symlinks kept. See `spikes/spike2-io/REPORT.md` | None needed. Escaped-UTF-8 decode for invalid bytes; raw bytes kept as read-only fallback | 2026-11-03 |
| 3 Rendered edit to patch | Pass, recommend GO. 174 scenarios at engine and WKWebView level, 27 browser-resolved cases, 0 round-trip mismatches in 56,175 blocks, 0 violations and 0 crashes in 126,565 fuzz edits. All input synthesized; IME and web-view undo are Spike 5. See `spikes/spike3-patches/REPORT.md` | None needed: `beforeinput` interception with Swift commands. Inline ranges come from an AST-guided walk rather than corrected cmark offsets, which replaces the approach in the Spike 1 report | 2026-11-04 |
| 4 Caret stability | Pass: caret and scroll undisturbed, no block node replaced, 60 keys/s at up to 100 KB, 39 of 39 checks plus 201 regression cases. Painting not checked by eye. See `spikes/spike4-stability/REPORT.md` | None needed. Editing must run off the main thread | 2026-11-04 |
| 5 IME and undo | Pass. One Swift undo stack, exact bytes after fuzz. Real Pinyin and Japanese pass the owner's manual test; step 13 found a Backspace bug, fixed and confirmed on retest. See `spikes/spike5-ime-undo/REPORT.md` | Patch on `compositionend`, own undo in Swift (the planned approach) | 2026-11-04 |
| 6 Preview security | Pass: in-tree images load; traversal, symlink escapes, non-images and remote images blocked; no document script ran; links go to the browser. See `spikes/spike6-security/REPORT.md` | None needed. Scheme `marklight-preview://doc/`; DOMPurify + strict CSP + page JS off, with Marklight JS in an isolated content world | 2026-11-03 |
