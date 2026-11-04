# Spike 5 report: IME composition and unified undo

**Result: undo PASS. IME PASS with real Pinyin and Japanese input, with one step awaiting a retest.** The owner ran [MANUAL-IME-TEST.md](MANUAL-IME-TEST.md) on 2026-11-04. Every step passed except step 13, which found a real bug, now fixed. The spike closes when step 13 passes again. The fallback, patching on `compositionend` and owning undo in Swift, is the design used here, and it's holding.

Date: 2026-11-04. macOS 26.5.2, Swift 6.3.3, release build. Throwaway code. This extends Spike 4 rather than Spike 3 as the prompt says, because Spike 3 rebuilt the whole DOM on each edit, which would destroy a composition.

## Results

| Check | Result |
|---|---|
| Real IME, manual test by the owner | All 18 steps passed except step 13 (fixed, retest pending) |
| IME protocol cases in a real `WKWebView` | **49 of 49** |
| Undo and redo through real Cmd-Z key events, across both panes | **19 of 19** |
| Spike 3 regression cases, plus the new empty-line cases | **217 of 217** |
| Spike 4 stability checks | **39 of 39** |
| Undo and redo for all 190 scenarios, engine level | Pass: exact bytes both ways |
| Undo-all and redo-all after random fuzz edits | **0 violations, 0 crashes** in 47,388 edits on the final code, across 6 seeds |
| Undo grouping unit tests | Pass |
| Mixed session: 120 edits across both panes, undone then redone by key | Exact bytes both ways |

## Scenario results against the pass criteria

| Pass criterion | Status | Evidence |
|---|---|---|
| No duplicated, lost, or reordered text; caret ends in the right place | Pass | Real Pinyin and Japanese, plus 49 protocol cases. See the list below |
| Candidate selection | Pass | Real candidate window, in the manual test |
| Cancelling with Escape | Pass | Real Pinyin and Japanese. Cancel also restores a deleted selection, including across blocks |
| Cmd-Z undoes the last edit, regardless of pane or focus | **Pass** | Both directions, with real key events |
| Undoing everything returns the original bytes | **Pass** | All scenarios, fuzz, and a mixed session |
| Buffer not patched mid-composition | Pass | Checked between updates. Patched once on `compositionend` |

The 49 protocol cases drive WebKit through `NSTextInputClient`, the same interface a real input method uses, so WebKit fires real composition events. They cover:

- **Input:** Pinyin steps, changing candidates, Japanese romaji then conversion, two compositions in a row, and composition before and after ordinary typing.
- **Follow-up keys:** Enter and Backspace straight after a commit.
- **Places:** inside and at the edges of bold, code, links, headings, lists, quotes, table cells, code blocks, empty cells, empty list items, new empty paragraphs, and CRLF files.
- **Selections:** replacing a selection within a block, across a mark, across blocks, and across list items.
- **Cancel:** with and without a selection, in an empty paragraph, and then typing.
- **The other pane:** source edits arriving mid-composition above, below, and inside the composing block, including inside it followed by a cancel.
- **Undo:** one undo removes one composition, and redo brings it back.

WebKit's sequence on commit: `compositionupdate`, `beforeinput insertCompositionText`, then at commit `deleteCompositionText`, `insertFromComposition`, and `compositionend`.

## How it works

**IME.** During composition the browser owns the DOM, and nothing can intercept that. So:

- At `compositionstart`, the page saves the selection as source offsets, plus a copy of every block it reaches.
- During composition the buffer doesn't change. Source-pane edits that reach the composing block are held. The saved range is kept pointing at the right text.
- On `compositionend` with text, the page sends one insert for the saved range, and the normal patch reconciles the DOM. With no text, it restores the saved blocks.

**Undo.** One stack lives on the buffer, in Swift, with `NSTextView.allowsUndo` off and WebKit's own undo never reached. Both panes send Cmd-Z and Cmd-Shift-Z to it.

- Typing groups into words: a step ends after a space, on a pause of a second, or when the caret jumps.
- Runs of Backspace group the same way.
- Structural edits, selection deletes, formatting, paste, and each composition are steps of their own.
- A step restores the selection from before it, and the pending-paragraph state.
- Any new edit clears redo.

## Found by the manual test

**Backspace couldn't delete the last character of a block.** With the only text in a paragraph, list item, or quote, Backspace did nothing. The safety net from Spike 3 refuses a collapsed Backspace that loses text at a block edge, and a block emptying itself looked like exactly that. It wasn't IME-specific, and it was in the Spike 3 and 4 copies too. The automated suites missed it because they only emptied a block with a selection, and the fuzzer counted these as refusals rather than failures. A refusal rate is worth reading, not just a violation count.

The fix marks that delete as deliberate. A line break left at the edge of a paragraph now goes with the line, which was a related refusal. 16 scenarios and 6 IME cases now cover this, including the exact sequence from step 13.

The owner also reported being unable to delete an empty line. Enter then Backspace worked in the automated tests even before the fix, so this may have been a result of the refused character, or something that only happens with a real IME active. The retest will tell.

## What needed special handling

1. **WebKit can delete the wrapper around a block mid-composition.** Composing into an empty table cell or list item unwrapped the top-level `div` and moved its contents into the root. Patches then went to a detached node: the text was right but the screen wasn't, and the caret vanished. **The DOM can't be trusted after a composition.** The page now checks that the top-level blocks are intact, and restores them on `compositionend`.
2. **A composition over a selection deletes it before the buffer knows,** possibly across blocks, so a cancel has to restore every block it reached.
3. **The key that ends a composition.** The page ignores `keyCode` 229 as well as `isComposing`, since Safari is known to report that key after `compositionend`. Only the guard is in place; the protocol tests send no key events, so this needs the manual test.
4. **Patches during composition** must not touch the selection, even for unrelated blocks, or the composition dies.

## Bridge changes needing approval

These extend the approved bridge contract, so they're proposals: a new `undo` message with `redo`; `composed` and `range` on `input`; and the Spike 4 changes this builds on. `docs/bridge.md` is unchanged.

## Open issues

- **Word grouping happens per message.** On a slow file, merged typing can put several words in one undo step.
- **Pending paragraphs are restored by undo, but a typed-then-undone edit can't bring back a selection in the other pane.** Focus and caret go to the pane that pressed Cmd-Z.
- **The Edit menu needs real Undo and Redo items in the app.** The spike leaves them out, and reads Cmd-Z from key events in each pane. A menu item has to route to the buffer too, and has to enable and disable properly.
- **Undo history doesn't survive a reload from disk.** External-change handling (M1) has to decide what happens to it.

## Not verified

- **Step 13 after the fix,** with a real IME.
- **Partial commits of Japanese clauses beyond step 10, reconversion, and `replacementRange`.**
- **Korean, Vietnamese, dictation, and press-and-hold accents,** which also use marked text.
- **A bundled app.** The manual test ran as a bare executable, and the input method worked. The macOS log line `error messaging the mach port for IMKCFRunLoopWakeUpReliable` appeared and had no visible effect.

## Running it

```bash
cd spikes/spike5-ime-undo && swift run -c release spike5-host --ime
```

```bash
cd spikes/spike5-ime-undo && swift run -c release spike5-host --interactive
```
