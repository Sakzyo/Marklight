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

## Approved after the spikes

All approved by the owner on 2026-11-04.

- Save strategy: resolve symlinks at open and use the resolved URL as the NSDocument `fileURL`; NSDocument safe save; in-place write when the file has more than one hard link (Spike 2).
- Remote images blocked by default, with a per-window "Load remote images" bar (Spike 6).
- Local file access root: the git repository root when the document is inside one, otherwise the document's folder; serve the page at the document's matching path so `../` resolves as on disk (Spike 6).
- `data-src` relative to the top-level block, with the block's offset held in JS (Spike 4). In `docs/contracts.md`.
- Bridge: version stamps; `marklight.load`, `patch`, and `done`; an `undo` message; `composed` and `range` on `input` (Spikes 4 and 5). In `docs/bridge.md`.
- Compare text by UTF-8 bytes, never `String ==`, which treats canonically equivalent text as equal (Spike 2).

## Defaults chosen for M1

- Minimum macOS stays 14: it's still within Apple's usual support window alongside macOS 15 and 26.
- Autosave is a setting, off by default, because silent in-place saves interact with git and file watchers (`docs/plan.md` 2.7). Coordinator can change this.

## Approved for M2

Approved by the owner on 2026-11-04, from the M2 plan.

- Bridge additions for selection sync: the `selection` message and `marklight.reveal(offset)`. In `docs/bridge.md`.
- M2 uses a subset of the bridge: `ready`, `selection`, `marklight.load`, `marklight.patch`, and `marklight.reveal`.
- First-launch layout is split, with Cmd-1, Cmd-2, and Cmd-3 for source, preview, and split. The choice is remembered for the whole app.
- highlight.js stays out of M2, because it would rewrite the code DOM that carries `data-run` offsets. Code block color can come with M5.
- Inline HTML stays a literal chip, as in Spike 3. Only HTML blocks go through the sanitizer.
- "Load remote images" allows `https:` only, and reloads the page with a wider CSP.
- Heading anchors are resolved in JS when a link is clicked. A stored `id` would depend on duplicate headings above it, so a block's HTML would change with the text above it.
- The buffer stays on the main thread in M2. Only parsing, rendering, and diffing move off it.

## Found while building M2

These came up during M2, and the owner hasn't reviewed them yet.

- Only a caret move on its own scrolls the preview. An edit carries the caret along, and if that scrolled the preview, scroll anchoring would be undone by the next keystroke. Undo and redo do scroll, to show what changed.
- Raw HTML travels as escaped text inside the `data-raw` element, and JS sanitizes it and expands it there. Sent as markup, a stray `</div>` could close the holder and put forged offsets outside it. The meaning in `docs/bridge.md` still holds, but what's on the wire differs from the spikes.
- The renderer leaves out `contenteditable` and the empty-leaf `<br>` until M3 needs them, and task checkboxes are `disabled` until M4. Empty leaves keep `data-caret`.
- `thead` and `tbody` are written explicitly, each with `data-src`. Otherwise the HTML parser would add a `tbody` with none.

## Found while building M3

These came up during M3, and the owner hasn't reviewed them yet. The evidence is in `docs/handoffs/m3-rendered-typing.md`.

- Top-level blocks sit in plain `div` wrappers of 64 under `#doc`, because WebKit's layout and paint loop over an element's direct children, and 15,000 of them cost more per key than everything else. The wrappers belong to the page. `docs/bridge.md` and `docs/contracts.md` didn't change: Swift still sends one entry per top-level block, and a block still holds its own offset. A wrapper has no `_base` and no `data-src`.
- `#doc` draws no focus ring. WebKit walks every box in the element to draw one, on every paint, and it showed as a line across the page.
- The `undo` bridge message stays. Menu commands and WebKit history events both go through it, so an undo stays ordered behind typing that hasn't reached Swift yet.
- Rendered typing can't be measured under `swift test`, because the test process never runs AppKit's event loop and WebKit treats the page as hidden. `TypingBench` measures it on a visible page. It's only part of the package when `MARKLIGHT_BENCH=1` is set, because it needs `@testable`, which a normal release build doesn't allow.
- Per-block editing hosts were considered and rejected. They would remove the last per-key cost that grows with the file (handoff, "Known limits"), but WebKit won't extend a selection or move a caret across editing hosts, so selecting across blocks would break.
- `#doc > div > div > :first-child { margin-top: 0; }` is the M2 rule with the new depth. Each block has one child, so it removes the top margin of every block, and the `1.5em` set on headings never applies. It's kept as it was, so the layout stays identical, but it may not be what was meant.

## Known gaps for milestones

- M2: top-level blocks are sanitized one at a time, so `<details>` or `<div align="center">` wrapping Markdown doesn't wrap it, and the opening tag closes inside its own block.
- M2: `<a name="x"></a>` on its own line is inline HTML in CommonMark, so it shows as a chip, and a link to it does nothing.
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
