# Spike 5 report: IME composition and unified undo

**Result: undo PASS. IME passes everything automation can reach, but isn't closed: no real input method has been run.** The fallback, patching on `compositionend` and owning undo in Swift, is the design used here, and it's holding.

To close the spike, someone has to run [MANUAL-IME-TEST.md](MANUAL-IME-TEST.md) with real Pinyin and Japanese input. It takes about ten minutes.

Date: 2026-11-04. macOS 26.5.2, Swift 6.3.3, release build. Throwaway code. This extends Spike 4 rather than Spike 3 as the prompt says, because Spike 3 rebuilt the whole DOM on each edit, which would destroy a composition.

## Results

| Check | Result |
|---|---|
| IME protocol cases in a real `WKWebView` | **43 of 43** |
| Undo and redo through real Cmd-Z key events, across both panes | **19 of 19** |
| Spike 3 regression cases | **201 of 201** |
| Spike 4 stability checks | **39 of 39** |
| Undo and redo for all 174 scenarios, engine level | Pass: exact bytes both ways |
| Undo-all and redo-all after random fuzz edits | **0 violations, 0 crashes** in 46,534 edits, across 5 seeds |
| Undo grouping unit tests | Pass |
| Mixed session: 120 edits across both panes, undone then redone by key | Exact bytes both ways |

## Scenario results against the pass criteria

| Pass criterion | Status | Evidence |
|---|---|---|
| No duplicated, lost, or reordered text; caret ends in the right place | Pass at protocol level | 43 cases. See the list below |
| Candidate selection | Protocol level only | Marked text changing before commit passes. The real candidate window wasn't run |
| Cancelling with Escape | Protocol level only | Cancel leaves the buffer alone and restores a deleted selection, including across blocks. How a real IME cancels wasn't observed |
| Cmd-Z undoes the last edit, regardless of pane or focus | **Pass** | Both directions, with real key events |
| Undoing everything returns the original bytes | **Pass** | All scenarios, fuzz, and a mixed session |
| Buffer not patched mid-composition | Pass | Checked between updates. Patched once on `compositionend` |

The 43 cases drive WebKit through `NSTextInputClient`, the same interface a real input method uses, so WebKit fires real composition events. They cover:

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

- **Any real input method.** This is the main gap, and it matters: real IMEs drive candidate windows, Escape, clause-by-clause commit, and key handling that the protocol tests only imitate.
- **Partial commits of Japanese clauses, reconversion, and `replacementRange`.**
- **Composition in the source pane.** It's a plain `NSTextView`, so it should work.
- **Clicking away or switching apps mid-composition.**
- **Korean, Vietnamese, dictation, and press-and-hold accents,** which also use marked text.

An interactive mode exists for the manual test (`--interactive`). It was only smoke-tested: it starts, loads the sample, and shows a window.

## Running it

```bash
cd spikes/spike5-ime-undo && swift run -c release spike5-host --ime
```

```bash
cd spikes/spike5-ime-undo && swift run -c release spike5-host --interactive
```
