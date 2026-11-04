# Handoff: M1, source editor

```
Task: M1, source editor, highlighting, zero-diff open/save, file handling
Branch: agent/core/m1-source-editor
Status: done, pending the owner's hands-on check
```

## What changed

**`Sources/MarklightCore/`** (no UI dependencies, Swift 6 mode):

- `TextCodec.swift`: encoding, BOM, and invalid-byte handling from Spike 2.
- `Patch.swift`: `Patch(range, replacement, origin)`, in UTF-16 units.
- `Buffer.swift`: the buffer, grouped undo and redo, observers, and line-ending lookup. Rejects a patch that splits a surrogate pair. Writes the original bytes back while the text is unchanged.
- `Parser.swift`: block tree, plus inline ranges from an AST-guided walk (Spike 3). Handles YAML front matter.
- `Highlighter.swift`: spans for the source pane, from the same parse the rendered pane will use.
- `HTMLRenderer.swift` and `BlockSerializer.swift` are still placeholders, for M2 and M4.

**`App/`**: a separate package, so the core stays free of UI. `scripts/build-app.sh` builds and ad-hoc signs `build/Marklight.app`.

- `MarkdownDocument.swift`: `NSDocument` subclass, hard-link-safe saves, and external-change detection.
- `SourceEditor.swift`: the `NSTextView` on TextKit 2, as a view of the buffer. Keeps line endings and keeps compositions out of the buffer until they commit.
- `SourceHighlighter.swift`: debounced, off the main thread, and only touches what changed.
- `MainMenu.swift`, `EditorWindowController.swift`, `MarklightApplication.swift`.

The app uses Swift 5 language mode, because NSDocument's overrides don't fit Swift 6 strict concurrency cleanly. The core uses Swift 6.

## Contracts touched

None changed by M1. `docs/contracts.md` and `docs/bridge.md` were updated beforehand with the changes approved after the spikes.

## Tests run

| Command | Result |
|---|---|
| `swift test` | 46 tests, including all 28 fixtures through open-save, the encoder alone, and edit-then-undo |
| `MARKLIGHT_CORPUS=<list> swift test` | 54,781 blocks in 400 real documents: 0 byte mismatches, 4 left read-only in the rendered sense |
| `swift test --package-path App` | 30 tests through real `NSDocument` and `NSTextView`, repeated runs |
| `scripts/build-app.sh`, then launching the bundle on a symlinked file | Opened the symlink's target, no crash, file untouched |

The app tests cover: no-op save and edit-undo-save for every fixture; line endings on Enter and paste; UTF-16, BOM, and invalid bytes surviving an edit; undecodable files opening read-only; mode, xattrs, symlinks, and hard links on save; a failed save leaving the document dirty; clean, dirty-keep, and dirty-reload external changes, including `git checkout`-style replacement; a deleted file; undo, redo, and menu validation; revert; untitled save-as; the find bar opening; composition; and highlighting following edits.

Timings at 850 KB in a release build: open 0.25 s, first highlight 0.26 s after that, keystroke 2 ms, save 0.2 s.

## Not verified

- **A person using it.** All app tests call the views directly. Nobody has typed into the real window yet.
- **How it looks,** in light or dark mode. Colors are system colors, so they should adapt, but nobody has looked. Line wrap, scrolling, and the window frame are the same.
- **Find and replace beyond the bar opening.**
- **The reload-or-keep alert itself.** Tests replace it with a stub.
- **A real IME in the source pane.** Spike 5's manual run passed on a plain `NSTextView`, but this one has composition handling that wasn't there then. Only the protocol path is tested.
- **The Finder path:** double-clicking a file, drag to Dock, and Open Recent.
- **Read-only files and locked folders** in the real save-error UI.
- **Network volumes, iCloud Drive, and exFAT.**

## Risks and open questions

- **Autosave** is off by default, and there's no settings UI yet: only `defaults write com.example.Marklight autosaveInPlace -bool true`, read at launch. That's a `docs/plan.md` default chosen for M1, so the owner may want to change it.
- **`docs/plan.md` is read-only** (mode 0444, set on 2026-11-04), so its open-item checkboxes weren't updated. The same decisions are in `docs/decisions.md`.
- **The buffer and the text storage are two copies of the text.** If they ever disagree, the buffer wins and the view resyncs. That path isn't tested.
- **Bold-italic and nested styles** use font traits, so a mark inside a heading looks the same as the heading.
- **The bundle identifier is still `com.example.Marklight`.**
- Dragging text inside the source pane doesn't normalize line endings the way paste does.

## Next step for whoever picks this up

M2: the read-only rendered view, built from `Parser.swift` and the Spike 4 patcher, with editing moved off the main thread from the start.
