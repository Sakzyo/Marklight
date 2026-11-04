# Bridge messages

The rendered pane's JS-to-Swift interface, as settled by Spikes 3, 4, and 5. Keep this surface minimal: JS reports events as source offsets, and Swift decides what they mean.

Approved by the owner on 2026-11-04. Changing it needs the Coordinator's approval (`AGENTS.md` section 3). Updated with the Spike 4 and 5 changes, approved the same day, and with `selection` and `marklight.reveal` for M2, also approved by the owner.

All offsets are UTF-16 code units into the decoded text (`docs/contracts.md`). The handler is registered only in the isolated content world (Spike 6), and Swift must check each message's shape against this list and drop anything else.

## JS to Swift

| `type` | Fields | When |
|---|---|---|
| `ready` | | The bridge has loaded |
| `input` | `v`, `inputType`, `data`, `start`, `end`, `target`, `targetV`, `composed`, `range` | `beforeinput`, with `preventDefault` called. Also sent from `keydown` for plain Backspace and Shift-Enter, which `beforeinput` doesn't reliably report, and from `compositionend` with `composed: true` |
| `paste` | `v`, `start`, `end`, `plain`, `blocks` | `paste`. `blocks` is null when the clipboard has no HTML |
| `toggle` | `v`, `kind`, `start`, `end` | Formatting shortcut. `kind` is `strong`, `em`, or `code` |
| `checkbox` | `v`, `checkbox`, `start`, `end` | `mousedown` on a task checkbox. `checkbox` is the item's start; `start` and `end` are the selection to restore |
| `undo` | `v`, `redo` | Cmd-Z or Cmd-Shift-Z, or `historyUndo` and `historyRedo` |
| `selection` | `v`, `start`, `end` | The user clicked or selected in the rendered pane. Sent from `mouseup` and from selection keys, not from `selectionchange`, so a DOM patch can't report a selection nobody made |

- `v` is the document version the page had applied, so Swift can carry offsets across edits it hadn't seen. `targetV` is the same for `target`, which is read when the event fires rather than when the message is sent.
- `start` and `end` are the selection. `target` is the first of `getTargetRanges()` as `[start, end]`, or null. `range` is the selection saved at `compositionstart`, and replaces the live selection.
- Only one message is in flight. Swift answers each with `marklight.done()`, and the page merges typing that arrives meanwhile.
- `blocks` is sanitized HTML flattened to `[{kind, runs: [{text, marks, href}]}]`. `kind` is `paragraph`, `h1` to `h6`, `bullet`, `ordered`, `quote`, or `code`.
- `inputType` values handled: `insertText`, `insertReplacementText`, `insertParagraph`, `insertLineBreak`, `deleteContentBackward`, `deleteContentForward`, `deleteWordBackward`, `deleteWordForward`, `deleteSoftLineBackward`, `deleteSoftLineForward`, `deleteHardLineBackward`, `deleteHardLineForward`, `deleteByCut`, `deleteContent`, `formatBold`, `formatItalic`.

## Swift to JS

| Call | Purpose |
|---|---|
| `marklight.load(list, v, start, end)` | Show a whole document. `list` is `[{html, base}]`, one per top-level block |
| `marklight.patch(m)` | Update changed blocks in place. `m`: `{v, from, remove, list, delta, local, caret, edits}` |
| `marklight.done()` | Swift has finished with the message in flight |
| `marklight.select(start, end)` | Set the selection |
| `marklight.selection()` | Read the selection as `[start, end]`, for menu commands |
| `marklight.reveal(offset)` | Scroll the block at `offset` into view if it's off screen. Doesn't touch the selection |

## Additions to the render output

Added to the `data-src` contract in `docs/contracts.md`:

| Attribute | Meaning |
|---|---|
| `data-run` | A span of text. Source offset = run start + DOM offset |
| `data-atomic` | A run that can't be entered: an escape, entity, break, or image. The caret sits before or after it |
| `data-caret="n"` | Where the caret goes in a leaf with no runs: an empty cell, list item, or pending paragraph |
| `data-raw` | Raw HTML from the document. JS strips offsets and `contenteditable` from everything inside it, so a document can't forge them |
