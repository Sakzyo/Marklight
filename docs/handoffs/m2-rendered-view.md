# Handoff: M2, read-only rendered view

```
Task: M2, read-only rendered view with source ranges, layouts, and selection sync
Branch: agent/preview/m2-rendered-view
Status: done, pending the owner's hands-on check. Not merged, not pushed
```

## What changed

**`Sources/MarklightCore/`**

- `HTMLRenderer.swift`: renders one top-level block at a time, with `data-src` relative to the block, and diffs two renders into a `BlockPatch`. It also reports whether a document has `https` images.
- `Parser.swift`: blocks now keep `rawHTML` and `columnAlignments`.

**`Resources/web/`**

- `preview.html`: the page and its styles, for light and dark.
- `preview.js`: block loading, the morph, scroll anchoring, selection reporting, and anchors. It runs in an isolated content world.
- `purify.min.js`: DOMPurify 3.4.17, from the npm tarball, checked against the registry's sha512. A test pins its hash. Its license is beside it.

**`App/`**

- `PreviewScheme.swift`: the `marklight-preview://doc/` origin, the access root, the path policy, and the CSP.
- `PreviewPane.swift`: the web view, navigation policy, link routing, bridge checks, context menu filter, and remote images bar.
- `PreviewUpdater.swift`: parsing, rendering, and diffing on their own queue, one update in flight, with edits coalesced.
- `EditorWindowController.swift`: the split view, layouts, and selection sync. `MainMenu.swift` gains the View menu.
- `SourceEditor.swift`: files now open with the caret at the start, not the end, and undo and redo tell the window where the caret went.
- `scripts/build-app.sh` copies `Resources/web/` into the bundle.

`Tests/Fixtures/attack.md` is new, ported from Spike 6, with forged-offset cases and raw HTML links added.

## Contracts touched

- `docs/bridge.md`: added the `selection` message and `marklight.reveal(offset)`, as the owner approved. M2 uses `ready`, `selection`, `marklight.load`, `marklight.patch`, and `marklight.reveal`.
- **Needs the owner's review:** raw HTML now travels as escaped text inside the `data-raw` element, and JS sanitizes and expands it there. As markup, a stray `</div>` could close the holder and put forged offsets outside it. The row in `docs/bridge.md` is still accurate, but what's on the wire differs from the spikes. See "Found while building M2" in `docs/decisions.md`.
- `docs/contracts.md`: unchanged.

## Tests run

| Command | Result |
|---|---|
| `swift test` | exit 0, 81 tests |
| `swift test --package-path App` | exit 0, 100 tests, twice in a row on the final code |
| `scripts/build-app.sh`, then launching the bundle | Split, preview-only, and a restored window all rendered, seen in window captures. No crash, and the files were untouched |
| `MARKLIGHT_TIMING=1 swift test --package-path App -c release -Xswiftc -enable-testing --filter PreviewTimingTests` | See below |

The app tests cover a hostile document in a real `WKWebView`, with a no-defences control; the path policy; links; a live DOM equal to a fresh render, node for node, for every fixture after random edits; node identity; scroll anchoring; zero-diff with the preview open for every fixture; layouts; the remote images bar; and selection sync.

**The tests can fail.** Fourteen deliberate breaks were each caught, including removing scroll anchoring, the echo guard, offset stripping, and the path bound. Four of them were rerun on the final code, and the rest just before the last selection and caret changes. The first round caught 10 of 11, and the miss exposed a weak scroll test, which now follows the text rather than the node.

One M1 test changed: `theMenuReachesItsActions` now expects the View menu. Nothing was weakened or skipped.

### Typing timings

180 keys at 60 a second, mid-file, in a release build, on a machine with a load average of about 4.

| Size | Layout | First render | Key median | Key max | Main thread late (max) | Updates | Preview caught up after |
|---|---|---|---|---|---|---|---|
| 4 KB | source | | 1.6 ms | 18.7 ms | 27.2 ms | | |
| 4 KB | split | 215 ms | 1.3 ms | 5.8 ms | 9.5 ms | 60 | 11 ms |
| 30 KB | source | | 1.5 ms | 6.6 ms | 11.2 ms | | |
| 30 KB | split | 206 ms | 1.0 ms | 6.0 ms | 8.8 ms | 54 | 34 ms |
| 100 KB | source | | 1.5 ms | 7.8 ms | 8.8 ms | | |
| 100 KB | split | 297 ms | 0.8 ms | 10.5 ms | 25.5 ms | 41 | 74 ms |
| 850 KB | source | | 3.1 ms | 6.4 ms | 5.1 ms | | |
| 850 KB | split | 1,180 ms | 1.7 ms | 9.1 ms | 11.6 ms | 10 | 286 ms |

The preview adds nothing measurable to a keystroke, so incremental parsing isn't needed for M2. Split is often lower than source because source always ran first, so read these as equal. At 850 KB the preview updates about three times a second while typing.

## Not verified

- **A person using it.** I launched the bundle and looked at captures, but nothing was clicked or typed in the real app. Test clicks are synthesized and sent to the view, because the test process is never the active app.
- **Light mode.** Only dark mode has been seen.
- **The real right-click menu.** The filter was tested on a menu I built, using WebKit's identifier names from memory. If a name is wrong, that item just goes missing.
- **A remote image actually loading.** Tests show the CSP stops blocking `https` images, against a host that can't resolve. The bar's button was fired through its action, not a mouse.
- **The real browser and a real second window.** Link routing was tested up to the point of opening, with the openers stubbed.
- **Typing with an IME while the preview is open.**
- **Dragging links or images out of the preview, and printing,** both left open by Spike 6.
- **Scroll anchoring while images load.** A late image above the viewport can still shift the text.
- **Independent review.** This was checked against `docs/plan.md` 2.6 by its author only. `AGENTS.md` section 10 calls for a separate reviewer.

## Risks and open questions

- **Typing past the bottom of the preview doesn't scroll it.** Only caret moves on their own do. Otherwise scroll anchoring would be undone by each keystroke. Undo and redo do scroll. This one is worth the owner's judgment after trying it.
- **HTML that wraps Markdown doesn't wrap it.** `<details>` and `<div align="center">` close inside their own block, so a details section shows its content while collapsed, and centered Markdown isn't centered. Both are common in READMEs.
- **`<a name="x"></a>` on its own line is a chip,** and a link to it does nothing. Other inline HTML, such as `<kbd>` and `<br>`, is a chip too, as approved.
- **`http` images stay blocked** even after "Load Remote Images".
- **Find does nothing in preview-only layout.**
- **Link and image titles are dropped.** Loose and tight lists look the same. A link to `other.md#section` opens the file at its top.
- **A saved window frame from M1 stays 760 wide,** so split can start cramped until the window is resized.
- **Each update parses twice,** once for highlighting and once for the preview. Both are off the main thread, so this is only wasted work.
- **Buffer observers run in an unstable order,** because they're held in a dictionary. This caused a flaky bug here. Don't rely on the order.
- **A `.source` patch that didn't come from the text view crashes the app on the next undo:** `SourceEditor.apply` raises an uncaught `NSRangeException`, not the resync the M1 handoff describes. M3 should know this before it adds patch sources.

### Testing lessons

- `NSButton.performClick` in a test leaves a run loop stop behind, and on Swift's async main that ends the whole test process with exit code 0 and no summary. The run looked clean with most tests unrun. Use `sendAction`. The harness now fails loudly if the process exits with a test open.
- Always look for the `Test run with N tests` line. A filter that matches nothing also exits 0.
- Tests here missed two bugs that a look at the real app found at once: the bar was 0 points tall, and restored windows had no preview.

## Next step for whoever picks this up

M3: fast-path rendered typing. Make the page `contenteditable`, and add the rest of the bridge from `docs/bridge.md`.
