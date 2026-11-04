# Prompt: M2, read-only rendered view

Build milestone M2 of Marklight: a read-only rendered view alongside the source editor, with source-range attributes, toggle and split layouts, and selection sync. M1 (the source editor) is done and on `main`.

**Read first:**

- `CLAUDE.md` and `AGENTS.md`
- `docs/contracts.md`, `docs/bridge.md`, and `docs/decisions.md`, including "Known gaps for milestones"
- `docs/handoffs/m1-source-editor.md`
- `docs/plan.md` sections 2.3 to 2.6 and 2.9
- `spikes/spike6-security/REPORT.md`
- `spikes/spike4-stability/REPORT.md`
- `spikes/spike3-patches/REPORT.md` (the renderer and rendering sections)

Work on a new branch, `agent/preview/m2-rendered-view`, from `main`. Commit in small steps. Don't push. Spike code is throwaway: reuse the ideas and rewrite the code, don't copy files or import from `spikes/`.

## Scope

**In:**

1. **`HTMLRenderer.swift` in `MarklightCore`.** Walk `ParsedDocument`, one top-level block at a time. Every element carries `data-src="start:end"` relative to its top-level block, in UTF-16 units. Follow the render attributes in `docs/bridge.md` (`data-run`, `data-atomic`, `data-caret`, `data-raw`). Do not use swift-markdown's `HTMLFormatter`: it doesn't escape attributes, which allows injection, and it drops image `alt` text (Spike 6). Render straight quotes: parsing already disables smart punctuation.
2. **Render scope:** headings, lists, task lists (shown, not yet toggleable), code blocks, GFM tables, inline marks, links, local images, and HTML blocks through the sanitizer. Front matter renders as a plain block. Mermaid and math are M6, so show them as code blocks for now.
3. **Preview pane in `App/`.** A `WKWebView` with the Spike 6 security setup: page JavaScript off, a strict CSP on the page, and all Marklight JS in an isolated content world. Bundle DOMPurify in `Resources/web/` with its license. highlight.js is in the approved stack if you use it for code blocks; pin a version, verify its integrity, and update `THIRD_PARTY_NOTICES`.
4. **Local files.** A `WKURLSchemeHandler` for `marklight-preview://doc/`. Access root: the git repository root when the document is inside one, otherwise the document's folder. Serve the page at the document's matching path, so `../` resolves as on disk. Use `realpath`, block symlink escapes, and serve image types only.
5. **Remote images** are blocked by default, with a per-window "Load remote images" bar.
6. **Links.** Real clicks on http, https, and mailto open the default browser. A click on a `.md` link inside the tree opens it in Marklight. `#anchor` links scroll. The preview never navigates away, and non-click navigations are dropped.
7. **Updates.** Patch only changed blocks and leave unchanged DOM nodes untouched, as Spike 4 showed. A preview update must never slow typing: parsing and rendering stay off the main thread. Keep the preview's scroll position stable with scroll anchoring, since WebKit doesn't do it. Coalesce updates while typing.
8. **Layouts.** Source only, preview only, and split, with a toggle in the View menu and a keyboard shortcut. Remember the choice.
9. **Selection sync.** Moving the source caret scrolls the preview to the matching block. Clicking or selecting in the preview moves the source caret to the matching range.

**Out:**

- Editing in the rendered pane (M3 and M4). The page isn't `contenteditable` yet, though the design shouldn't block it.
- Checkbox toggling (M4). Mermaid, math, and edit-in-place (M6).
- Incremental parsing, unless M2 can't stay smooth without it. If so, stop and say so.
- Anything from the "Later" or "Never" tiers in `docs/plan.md`.

Keep the bridge to what M2 needs. It should be a subset of `docs/bridge.md`. Any new or changed message is a contract change, so ask first.

## Tests

- Renderer tests in `Tests/MarklightCoreTests/`: every fixture renders with valid in-bounds `data-src` on every element; attribute escaping, including the link breakout from Spike 6; `alt` text; a block's HTML doesn't change when text above it does.
- A real `WKWebView` test in `App/Tests/`: load a hostile document, and confirm nothing from it runs, the sanitizer holds, and traversal, symlink escapes, and remote images are blocked, with relative images loading. Port the attack cases from `spikes/spike6-security/fixtures/attack.md`. Add a no-defences control run so the test is known to detect attacks.
- After updates, the live DOM must equal a fresh render, node for node.
- Unchanged blocks keep their DOM nodes, checked by node identity.
- The scroll position holds when the source pane edits text above the viewport. Confirm that test fails with anchoring removed.
- Zero-diff stays intact: with the preview open, open-no-op-save is still byte-identical for every fixture.
- Run `swift test`, `swift test --package-path App`, and `scripts/build-app.sh`, and launch the real bundle.

## Lessons from earlier work

- Treat a passing summary with suspicion. A crash once showed up only as blank output, so check exit codes.
- A test that has never failed proves little. Show that key tests can fail.
- A held reference matters in tests: a document discarded with `let (_, view, _)` is freed before async work finishes.
- WebKit's behavior differs from what you'd assume. Test in a real `WKWebView`, not just the engine.
- Heavy work on the main thread stalls WebKit's key delivery, which hides latency from timers in the page.

## Rules

- `docs/plan.md` is read-only on purpose. Leave its permissions alone; record decisions in `docs/decisions.md`.
- Ask before adding a dependency beyond those listed in `CLAUDE.md`, or changing anything in `docs/contracts.md` or `docs/bridge.md`.
- Say plainly what wasn't verified. Automated tests can't judge how it looks, so list what a person should check.

## Finish

Write `docs/handoffs/m2-rendered-view.md` in the format of `AGENTS.md` section 8. Don't merge: tell me what passed, what wasn't verified, and what to try by hand.
