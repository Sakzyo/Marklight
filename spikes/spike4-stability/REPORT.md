# Spike 4 report: caret and scroll stability under DOM patching

**Result: PASS.** The fallback (suppressing updates to the focused block) wasn't needed. Edits in either pane update the other without moving the caret, jumping the scroll, or replacing any block node, including at 60 keystrokes per second.

The main finding is architectural: **editing has to run off the main thread.** Two contract changes follow from this spike and need approval (see below).

Date: 2026-11-04. macOS 26.5.2, Swift 6.3.3, release build, on a machine with other apps running. Throwaway code, extending the Spike 3 prototype.

## What was built

A window with a real `WKWebView` and a real `NSTextView` on TextKit 2, sharing one buffer, under the Spike 6 security setup.

- **Relative offsets.** Each top-level block renders with `data-src` relative to its own start. Its source offset lives in a JS property, not in the DOM. So text above a block can change without touching the block at all.
- **Block diff.** Swift diffs the rendered blocks against what it last sent, and sends only the changed range. Edits made during a sync collapse into the next one.
- **Morph.** A changed block is turned into its new form in place, keeping every node it can. It's about 40 lines, written here, with no new dependency.
- **Origin tagging.** Swift's own writes to the source pane are tagged, so they never echo back. Rendered-pane edits are applied by Swift's patch, never by the browser.
- **One edit in flight.** The page sends one message at a time and merges typing that arrives meanwhile.
- **Version stamps.** Messages carry the version the page had applied, so Swift can carry offsets across source-pane edits the page hadn't seen.
- **Scroll anchoring.** Before a remote patch, the page records the top block's position and restores it after. WebKit has no built-in scroll anchoring.

## Results

| Pass criterion | Result |
|---|---|
| Caret doesn't move when the source pane edits another block | Pass: same DOM node and same offset, whether the edit is above or below. The selection still maps to the right source text, and the next typed key lands correctly |
| Scroll doesn't jump on remote updates | Pass: visible block moved 0.0 px for paragraphs inserted above, removed above, a block above growing, and an edit below |
| No flicker or feedback loop at 60 keys/s | Pass, at 3, 30, and 100 KB. No blocks replaced, every key in order, no echo. See caveat under "Not verified" |
| Unchanged block never replaces its DOM node | Pass: 0 of 1,965 elements lost on typing, 0 of 1,977 on a remote edit, checked by node identity |

Also: **39 of 39** stability checks and **201 of 201** Spike 3 regression cases pass through the patcher, in two full runs. After each regression case, the DOM matched a fresh render node for node, and the source pane matched the buffer.

Other cases that pass: a remote edit in the focused block (the caret moves with its text), a remote delete around the caret, the whole document replaced, the caret returning after focus moves to the source pane and back, a preview edit moving the source pane's caret with its text with no scroll jump, and both panes editing at once with both streams intact.

A control confirms the tests can fail: with the scroll restore and the move queue removed, 5 checks fail (blocks moved 248 to 306 px, and typed text came out as `xy` instead of `yx`).

### Measurements

Nodes touched per edit, in a 13 KB document of 210 blocks:

| Edit | Added | Removed | Text changed | Attributes |
|---|---|---|---|---|
| Type one letter | 0 | 0 | 1 | 14 |
| Source-pane edit in another block | 0 | 0 | 1 | |
| Enter in a 500-item list | 1 | 2 | 1 | 3,490 |

60 keys/s for 3 seconds, 180 keys:

| Document | Messages | All in buffer at | Key to DOM, median | p95 | DOM patch | Main thread late by (max) |
|---|---|---|---|---|---|---|
| 3 KB | 180 | 2.99 s | 5 ms | 7 ms | 1 ms | 7 ms |
| 30 KB | 108 | 3.01 s | 42 ms | 58 ms | 1 ms | 4 ms |
| 100 KB | 35 | 3.12 s | 135 ms | 177 ms | 2 ms | 4 ms |

Key to DOM is measured from when the page sees the key to when the patch finishes. It doesn't include paint. DOM patching is cheap; nearly all the latency is the whole-file re-parse from Spike 3, so 30 KB keeps up but feels slightly behind at this speed.

## What failed and how it was fixed

1. **Parsing on the main thread stalled the keyboard.** The first run looked fine: 180 keys, 180 messages. But it was misleading. WebKit forwards each key only after the main thread has handled the previous one, so keys queued up where the page's timer couldn't see them, and merging never happened. Moving the editor to its own serial queue fixed it: 180 keys became 35 messages at 100 KB, and the main thread stays within a few milliseconds. **The app must do this.** It adds work: a rendered-pane patch can cross a source-pane key in flight, so `mirror` has to carry patches across source edits.
2. **Keys during an in-flight edit.** With a slow parse, typing a letter then pressing Left moved the caret on a DOM that didn't have the letter yet, so text landed in the wrong order. Navigation keys now wait in the same queue and replay with `Selection.modify`. Only arrow keys are replayed; Home, End, and Page keys aren't yet.
3. **WebKit clears the selection when the web view loses focus,** and puts the caret at the start when it returns. The page now remembers the selection, keeps it pointing at the same text through patches, and restores it.
4. **A positional diff rewrote every later list item.** Enter in a 500-item list changed 499 text nodes. Matching children from the end first brought that to 1.
5. **Replacing `innerHTML` in the Spike 3 path** is gone. Text node identity survives typing.

## Contract changes needing approval

Both change approved contracts, so they're proposals until the Coordinator agrees (`AGENTS.md` section 3). This spike's code uses them; `docs/contracts.md` and `docs/bridge.md` are unchanged.

1. **`data-src` becomes relative to the top-level block**, with the block's offset held in JS. Without this, every edit would rewrite offsets in every later block.
2. **Bridge changes:** messages gain `v` and `targetV`. Swift-to-JS becomes `marklight.load`, `marklight.patch`, and `marklight.done` in place of `marklight.update`.

## Open issues

- **The 500-item list still costs 3,490 attribute writes and about 33 ms** in the page, because offsets are relative to the whole list. A long list or table is one top-level block. If that matters, offsets could be relative to each list item.
- **Text typed into a slow document appears late.** At 100 KB, about 135 ms. Incremental parsing (from Spike 3) is the real fix. Inserting typed text into the DOM optimistically is the alternative, at the cost of the clean "Swift decides" rule.
- **Rendering on the queue while the source pane types** runs once per key (180 renders for 180 keys in the 13 KB document). It keeps up here, but should be debounced for large files.
- **Mouse clicks during an in-flight edit** aren't queued. Clicks hit a slightly stale DOM, though the selection is carried across the edit afterwards.

## Not verified

- **Actual painting.** "No flicker" rests on no block node being replaced, not on watching frames. The test window is invisible, and it needs a human look in a real window.
- **Real keyboard timing, IME during a patch,** and how a real active window behaves. Spike 5 covers composition.
- **Remote updates while an image or a long code block loads,** which can change layout after the anchor is restored.
- **Scroll anchoring when the top visible block is the one that changed.** It anchors to the block's top, so text inside a tall block could still shift.

## Running it

```bash
cd spikes/spike4-stability && swift run -c release spike4-host
```

`--stability` skips the regression cases.
