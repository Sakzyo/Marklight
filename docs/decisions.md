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

## Spike results

| Spike | Result | Fallback taken | Date |
|---|---|---|---|
| 1 Source ranges | | | |
| 2 Zero-diff I/O | | | |
| 3 Rendered edit to patch | | | |
| 4 Caret stability | | | |
| 5 IME and undo | | | |
| 6 Preview security | | | |
