# Prompt: M3, rendered typing

Build milestone M3 of Marklight: typing and deleting inside text runs in the rendered pane, with each edit becoming one minimal patch on the buffer. M1 and M2 are done and on `main`. This is the fast path from `docs/plan.md` 2.2. Structural editing is M4.

**Read first:**

- `CLAUDE.md` and `AGENTS.md`
- `docs/contracts.md`, `docs/bridge.md`, and `docs/decisions.md`, including "Found while building M2" and "Known gaps for milestones"
- `docs/handoffs/m2-rendered-view.md`, especially the timings, risks, and testing lessons
- `docs/plan.md` sections 2.1, 2.2, and 2.9
- `spikes/spike3-patches/REPORT.md`: the approach, what needed special handling, and performance
- `spikes/spike4-stability/REPORT.md`
- `spikes/spike5-ime-undo/REPORT.md` and `spikes/spike5-ime-undo/MANUAL-IME-TEST.md`

Work on a new branch, `agent/core/m3-rendered-typing`, from `main`. Commit in small steps. Don't push. Spike code is throwaway: reuse the ideas and rewrite the code, don't copy files or import from `spikes/`. Porting test cases is fine.

Give me a short plan before writing code.

## Scope

**In:**

1. **Parsing for the edit path, first and timeboxed.** Keystroke cost must stop growing with file size. Spike 3's idea, not yet tried: verify only the edited top-level block and its neighbours, then run a full check when typing pauses, off the main thread. Do this before the rest, and prove it with a differential test: after every edit in the fuzzer, the incremental result must equal a full parse (block kinds, ranges, atoms). This is needed for rendered typing only. M2's timings show the source pane stays smooth on full parses, so leave that path alone unless the numbers change. Known hazards: a block parsed alone loses the document's link reference definitions; a block can change what its neighbours mean; and fences, lazy continuation lines, CRLF, and front matter all have edge cases. If the idle check ever disagrees with the incremental result, re-render from the full parse and report it. If this can't pass, stop and say so (see "Stop and ask").
2. **Inline editing in `BlockSerializer.swift`.** An edit changes one leaf's atom list and regenerates only that leaf, reusing the original bytes of every unchanged atom. The result is diffed into one minimal `Patch(range, replacement, .rendered)`. Verify every edit before it commits by parsing the candidate. If it doesn't match the expected structure, retry the way Spike 3 did: raw, then escaped, then the other options. If nothing matches, refuse the edit and leave the document unchanged. **An edit that can't be proven correct doesn't happen.**
3. **Editing off the main thread.** Spike 4 found that heavy work on the main thread stalls WebKit's key delivery. Recommended design: the buffer stays on the main thread, where applying a patch is cheap. Parsing and verifying run on a serial queue against a snapshot, and the result is carried across any source-pane edits that arrived meanwhile. If you choose differently, say why in the plan. Rendered edits skip the updater's delay.
4. **Rendered pane editing.** Make the page `contenteditable`, with `contenteditable="false"` on everything M3 can't edit. Intercept `beforeinput`, call `preventDefault`, and let Swift decide. The DOM changes only through patches from Swift, never by the browser. Bring in the empty-leaf `<br>` and `data-caret` handling M2 left out.
5. **What can be edited:** text in paragraphs, headings, list items, and quotes. That covers typing, replacing a selection within one leaf, Backspace and Delete, and word and line deletes. Deleting the last character of a block must work (Spike 5, step 13), which brings in Spike 3's pending-paragraph caret position.
6. **Everything else is refused, visibly.** Every `beforeinput` that isn't handled is prevented, so the DOM can't drift. A refused edit calls `NSSound.beep()`, changes nothing, and leaves the DOM equal to a fresh render. That covers Enter, Backspace at a block's start, deletes across blocks, paste, cut across blocks, drops, and formatting shortcuts, until M4. Typing into code blocks and tables is M5.
7. **Typing stays literal.** `# ` or `**x**` typed in the rendered pane is text, as in Spike 3. Follow its rules: `2 * 3` stays as is, and specials are escaped only if the structure would otherwise change.
8. **IME.** Follow Spike 5: no buffer change during composition, one patch on `compositionend`, the DOM restored after a cancel, and top-level blocks checked afterwards, because WebKit can delete their wrappers. A patch during composition mustn't touch the selection.
9. **One undo stack.** Cmd-Z and Cmd-Shift-Z work from either pane, and the selection comes back in the pane that pressed them. WebKit's own undo must never run. M2 already routes the Edit menu through `PreviewWebView`, so check whether the `undo` message is still needed. If it isn't, leave it out and say so.
10. **Both panes in sync.** A rendered edit reaches the source pane without moving its caret or scroll, and a source edit reaches the rendered pane without moving its caret or scroll. Follow Spike 4: one message in flight, typing merged while one is out, navigation keys queued and replayed, and the selection remembered across focus changes. Add Home, End, and the Page keys, which Spike 4 left out. Fix the crash in `SourceEditor.apply`: a patch that doesn't fit the text storage must resync, not raise.
11. **Links.** A plain click in an editable pane places the caret, and Cmd-click follows the link through M2's routing. Anchor links work the same way.
12. **Turn off what bypasses `beforeinput`.** Spell check, autocorrect, smart quotes, and text substitution stay off in the rendered pane for M3.

**Out:**

- Enter, block merges, lists, headings, quotes, inline formatting, paste, and task checkboxes (M4).
- Tables, images, and code blocks in the rendered pane (M5). Mermaid, math, and HTML blocks (M6).
- Markdown auto-formatting while typing, and anything from the "Later" or "Never" tiers in `docs/plan.md`.
- Find in the rendered pane, and autosave or recovery. Both are still needed before v1.

The bridge should stay a subset of `docs/bridge.md`: `ready`, `selection`, `input`, `marklight.load`, `marklight.patch`, `marklight.done`, `marklight.select`, `marklight.selection`, and `marklight.reveal`, plus `undo` if it's needed. Any new or changed message is a contract change, so ask first.

## Performance targets

Measure in a release build, extending `PreviewTimingTests`, and report the same sizes as M2: 4, 30, 100, and 850 KB.

- Key to DOM, not counting paint, at 60 keys a second: p95 under 20 ms at 100 KB and under 50 ms at 850 KB. Spike 4 measured 135 ms at 100 KB.
- Nothing typed is lost or reordered at any size.
- Main thread lateness and source-pane key cost no worse than M2's table.

## Tests

Check that each one has failed at least once.

- **Engine scenarios in `Tests/MarklightCoreTests/`,** ported from Spike 3 and Spike 5: typing, deleting, preservation, the Spike 1 bugs, and the fuzz-found cases that apply to text runs. Each checks source bytes, the caret, the re-parsed structure, and undo to exact bytes. Cover CRLF, mixed endings, emoji, CJK, combining marks, entities, delimiter styles, hard breaks, and reference links.
- **A fuzzer in `Tests/`,** seeded and repeatable, with a small default and a larger run behind an environment variable. Independent checks: the patch reproduces the result, blocks outside the patch parse the same, no block becomes unmappable, every block round-trips, undoing everything restores the original bytes, and incremental equals full. Report the refusal rate by operation and read it: Spike 5's Backspace bug was hiding in a refusal count.
- **The same scenarios through a real `WKWebView`,** with real key events. After every edit, the live DOM must equal a fresh render node for node, and the source pane must equal the buffer.
- **Stability:** the caret stays on the same node and offset when the other pane edits another block, and the next key lands correctly. Scroll holds in both panes. Unchanged blocks keep their nodes. 60 keys a second at each size, with a control showing the test can fail.
- **IME protocol cases through `NSTextInputClient`,** ported from Spike 5, for the places M3 can edit.
- **Undo through real Cmd-Z events** in both panes, including a mixed session that undoes to exact bytes.
- **Refusals:** each one leaves the buffer untouched and the DOM equal to a fresh render.
- **Security:** M2's hostile-document suite still passes with the page editable. Message offsets are untrusted: out-of-range values, values that split a surrogate pair, and targets in raw HTML or other read-only blocks are all refused. Raw HTML can't turn itself editable. Keep the no-defences control.
- **Zero-diff:** every existing golden test still passes. Typing and then deleting back to the original text leaves `isDirty` false and saves the original bytes, through the real document.
- **Deliberate breaks:** remove anchoring, verification, origin tagging, the offset checks, and the incremental fallback, one at a time, and show the tests catch each one.
- Run `swift test`, `swift test --package-path App`, and `scripts/build-app.sh`, then launch the real bundle and look at it, in light and dark mode.

## Lessons from earlier work

- Treat a passing summary with suspicion. Find the `Test run with N tests` line every time. M2 had a run that stopped early with exit code 0 and no summary, and a filter that matches nothing also exits 0.
- `NSButton.performClick` in a test ends the whole test process. Use `sendAction`.
- Look at the real app. M2's tests missed a 0-point-tall bar and restored windows with no preview, and one look at the bundle found both.
- A plain first click is swallowed by a window that isn't key, and this test process is never the active app. Spike 3 used a window that reports itself as key, which keyboard tests will need too.
- Check what a test is really watching. A reused node showing other text passed M2's first scroll test, and a clicked block is always on screen, so scroll position couldn't show an echo.
- Buffer observers run in an unstable order, so nothing may depend on it. A flaky result is a real result.
- Heavy work on the main thread stalls WebKit's key delivery, which hides latency from timers in the page.
- WebKit can restructure the DOM during composition. Don't trust it afterwards.
- A held reference matters in tests: a document discarded with `let (_, view, _)` is freed before async work finishes.

## Rules

- `docs/plan.md` is read-only on purpose. Leave its permissions alone, and record decisions in `docs/decisions.md`.
- Ask before adding a dependency beyond those listed in `CLAUDE.md`, or changing anything in `docs/contracts.md` or `docs/bridge.md`.
- Never regenerate a file from an AST. Every unchanged atom keeps its original bytes.
- Fixtures are append-only.
- Say plainly what wasn't verified. Nobody can judge real typing feel or real IME from automated tests, so list what a person should check.

## Stop and ask

- The incremental path can't pass the differential test. Report what diverged, and the keystroke cost with the full-parse fallback. Don't ship an incremental result that can disagree with a full parse.
- The performance targets can't be met.
- A rule from `docs/plan.md` 2.2 can't be kept, or the go/no-go rule in `CLAUDE.md` looks like it applies.
- The same failure repeats after two attempts.

## Finish

Adapt the steps in `spikes/spike5-ime-undo/MANUAL-IME-TEST.md` into a manual test for the real app, in `docs/`, for the owner to run. Write `docs/handoffs/m3-rendered-typing.md` in the format of `AGENTS.md` section 8. Don't merge: tell me what passed, what wasn't verified, and what to try by hand.
