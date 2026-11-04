# Bridge messages

The rendered pane's JS-to-Swift interface, as settled by Spike 3 (`spikes/spike3-patches/REPORT.md`). Keep this surface minimal: JS reports events as source offsets, and Swift decides what they mean.

**Status: proposed, awaiting Coordinator approval.** Spike 5 will add composition and undo.

All offsets are UTF-16 code units into the decoded text (`docs/contracts.md`). The handler is registered only in the isolated content world (Spike 6), and Swift must check each message's shape against this list and drop anything else.

## JS to Swift

| `type` | Fields | When |
|---|---|---|
| `ready` | | The bridge has loaded |
| `input` | `inputType`, `data`, `start`, `end`, `target` | `beforeinput`, with `preventDefault` called. Also sent from `keydown` for plain Backspace and Shift-Enter, which `beforeinput` doesn't reliably report |
| `paste` | `start`, `end`, `plain`, `blocks` | `paste`. `blocks` is null when the clipboard has no HTML |
| `toggle` | `kind`, `start`, `end` | Formatting shortcut. `kind` is `strong`, `em`, or `code` |
| `checkbox` | `at`, `start`, `end` | `mousedown` on a task checkbox. `at` is the item's start; `start` and `end` are the selection to restore |

- `start` and `end` are the selection. `target` is the first of `getTargetRanges()` as `[start, end]`, or null.
- `blocks` is sanitized HTML flattened to `[{kind, runs: [{text, marks, href}]}]`. `kind` is `paragraph`, `h1` to `h6`, `bullet`, `ordered`, `quote`, or `code`.
- `inputType` values handled: `insertText`, `insertReplacementText`, `insertParagraph`, `insertLineBreak`, `deleteContentBackward`, `deleteContentForward`, `deleteWordBackward`, `deleteWordForward`, `deleteSoftLineBackward`, `deleteSoftLineForward`, `deleteHardLineBackward`, `deleteHardLineForward`, `deleteByCut`, `deleteContent`, `formatBold`, `formatItalic`.

## Swift to JS

| Call | Purpose |
|---|---|
| `marklight.update(html, start, end)` | Sanitize and show `html`, then set the selection. Spike 4 replaces this with block-level DOM patches |
| `marklight.select(start, end)` | Set the selection |
| `marklight.selection()` | Read the selection as `[start, end]`, for menu commands |

## Additions to the render output

Added to the `data-src` contract in `docs/contracts.md`:

| Attribute | Meaning |
|---|---|
| `data-run` | A span of text. Source offset = run start + DOM offset |
| `data-atomic` | A run that can't be entered: an escape, entity, break, or image. The caret sits before or after it |
| `data-caret="n"` | Where the caret goes in a leaf with no runs: an empty cell, list item, or pending paragraph |
| `data-raw` | Raw HTML from the document. JS strips offsets and `contenteditable` from everything inside it, so a document can't forge them |
