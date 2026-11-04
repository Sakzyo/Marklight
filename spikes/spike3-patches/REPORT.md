# Spike 3 report: rendered edit to source patch

**Result: PASS. Recommendation: GO.** Edits in a real `contenteditable` DOM become single, minimal patches against the Markdown source, and untouched text stays byte-identical. The go/no-go fallback in `CLAUDE.md` isn't needed. Free typing and structural editing in the rendered pane stay in scope for v1.

Main risk carried forward: every edit re-parses the whole file, so typing lags on very large files (see "Performance"). IME and undo in the web view are Spike 5 and aren't covered here. All input in these tests was synthesized; no person has typed into this yet.

Date: 2026-11-04. swift-markdown 0.9.0, macOS 26.5.2, Swift 6.3.3. Throwaway code.

## How it works

The `beforeinput` approach from the plan held up. Page JS reports an event as source offsets, Swift decides everything, and the page applies what Swift sends back.

1. **Atoms.** Each text block is walked with the AST as a guide, and every rendered UTF-16 unit is recorded with the exact source it came from. `\*` is one atom covering two source units; `&amp;` likewise. Delimiters are stored on marks with their exact bytes (`__`, not a generic "bold"), so unchanged text writes back identically.
2. **Only block ranges come from cmark.** This goes further than the Spike 1 recommendation, which proposed correcting cmark's inline offsets. The walker ignores them entirely, which avoids Spike 1 bugs 1 to 4 outright.
3. **An edit changes the atom list, then regenerates that one block.** Original bytes are reused for every unchanged atom. The result is diffed against the old text to give one minimal `Patch`.
4. **Every edit is verified before it commits.** The candidate text is re-parsed and its structure compared with the expected structure. If that fails, it retries: plain, then escaped, then wider code fences, then stars instead of `_`, and so on. If nothing matches, the edit is refused and the document doesn't change. **An edit that can't be proven correct doesn't happen.**
5. **Block edits are checked too.** Blocks outside the patch must parse as before, and Enter or Backspace at a block edge must not lose text.

The `Patch` contract needed no change: every command produces exactly one `Patch(range, replacement, origin)`, in UTF-16 units.

The spike ran under the Spike 6 security setup: page JS off, strict CSP, DOMPurify, and all Marklight JS in an isolated content world. `contenteditable`, `beforeinput` and selection all work in that setup.

## Results

| Check | Result |
|---|---|
| Scenarios, engine level (`swift test`) | **174 of 174**: source bytes, caret, re-parsed structure, and undo to exact bytes |
| Same scenarios through a real `WKWebView` | **174 of 174**, three runs in a row |
| Browser-resolved input (word and line delete, arrows, shift-selection, mouse clicks, select all) | **27 of 27**, three runs in a row |
| Round trip: regenerate every block with no edit | **0 mismatches** in 56,175 blocks |
| Blocks that couldn't be mapped (safely read-only) | 14 of 56,175 |
| Fuzz: random edits, independent checks | **0 violations, 0 crashes** in 126,565 edits |
| Plain letters typed at random positions in real files | **5,243 of 5,243 applied** |

Corpus: 400 real Markdown files on this Mac, 728 CommonMark and GFM spec examples, and the project's fixtures. The fuzz skips the 5 real files over 120 KB, because each edit re-parses the file; they're included in the round-trip check. A deliberately broken scenario fails, so the suite can detect failures.

The fuzzer's independent checks: the patch reproduces the result, blocks outside the patch parse the same, Enter and edge Backspace lose no text, no block becomes unmappable, every block still round-trips, and undoing everything restores the original bytes.

Getting to zero took real work. The fuzzer found 48 violations in its first run, then more as the coverage widened, including one crash that was hiding as blank output in a summary. Each is now a scenario (section `fuzzFound` in `ScenarioData.swift`). Earlier seeds were not all clean. The numbers above are the final runs on the final code. Fuzzing can't prove the absence of bugs, so keep it in CI.

### Scenario table

Every group below passes at both engine and WebKit level.

| Group | Count | Covers |
|---|---|---|
| Typing | 12 | Mid-word, at run boundaries, inside bold, literal `*` `#` `-` `1.` and backticks, emoji in CJK |
| Deleting | 23 | Across inline boundaries, whole words, emoji clusters, CJK, combining marks, across paragraphs, merging, at document start, rules |
| Enter | 9 | Paragraph, inside bold, selection, heading, Shift-Enter |
| Lists | 19 | Enter in, at end of, and on empty items; nested, ordered renumbering, all-ones, task, loose; Backspace at item start; checkboxes |
| Quotes | 10 | Enter, Backspace, leaving a quote, lists in quotes, continuation lines |
| Formatting | 18 | Partial bold, unbold mid-run, overlapping marks, italic, code, strikethrough, per-file `_` style, CJK and emoji |
| Headings | 9 | Level changes, to and from paragraph, setext, closing hashes |
| Paste | 12 | Plain, specials, multi-line, into quotes and bold, rich inline, links, rich blocks |
| Tables | 10 | Typing, pipes, escaped pipes, empty cells, bold, emoji, refusing cross-cell delete |
| Preservation | 16 | CRLF, mixed endings, entities, delimiter style and order, hard breaks, reference links, images, inline HTML |
| Spike 1 bugs | 7 | All the inline position bugs, including backslash breaks and lazy continuation lines |
| Code blocks | 5 | Typing, Enter, literal text, code in lists |
| Found by fuzzing | 24 | Heading adjacency, links, autolinks, badges, indented code |

### Fuzz results on real files

63,055 of the 126,565 edits. Refused means the document was left unchanged.

| Operation | Applied | No-op | Refused | Refused % |
|---|---|---|---|---|
| Insert a letter | 5,243 | 0 | 0 | 0.00% |
| Insert a special character | 10,306 | 10 | 34 | 0.33% |
| Backspace | 5,207 | 41 | 26 | 0.49% |
| Delete a range in a block | 5,199 | 10 | 49 | 0.93% |
| Backspace at block start | 4,374 | 923 | 93 | 1.73% |
| Paste plain | 5,145 | 0 | 125 | 2.37% |
| Enter | 5,158 | 0 | 289 | 5.31% |
| Paste rich | 4,701 | 0 | 509 | 9.77% |
| Heading change | 3,473 | 1,056 | 654 | 12.62% |
| Delete across blocks | 3,982 | 0 | 1,161 | 22.57% |
| Toggle mark | 3,951 | 0 | 1,336 | 25.27% |

These positions and selections are random, so they include many the UI wouldn't offer. Most refusals are deliberate rules: 990 selections crossing a table or code block, 654 headings on non-text blocks, 395 marks in code blocks, 267 Enter in a table cell, 239 toggles with nothing selected. The rest:

- **1,399 "no serialization matches".** Valid Markdown can't express the result. Examples are bold that would close right after punctuation before a letter, and characters not legal in an `<autolink>`. These weren't broken down by operation, so how many hit normal formatting use is unmeasured. Toggle mark and paste rich are the ones to look at.
- **285 caught by the block safety net**, for example a list item's nested children reparenting after a cross-block delete. Correct to refuse, but some could become smarter edits in M4.

## Edit types that needed special handling

**Where `beforeinput` isn't enough (found only by real WebKit):**

- **Backspace at the start of the document fires no `beforeinput`.** Plain Backspace is taken from `keydown` instead.
- **Shift-Enter** arrived as `insertParagraph` from the synthesized key event, so it's also taken from `keydown`. Real keyboards may differ.
- **Checkboxes inside an editable root get no `click`.** `mousedown` is used.
- **Word and line deletes** use `getTargetRanges()`, which always had a range. WebKit's own word breaks are used, including for CJK.

**Inline:**

- Typed specials stay literal: try raw, then escape only if the structure would change. `2 * 3` stays as is; `*a` then `*` becomes `*a\*`. If new text pairs with old text, old text is escaped too.
- Marks can't start or end on whitespace, so spaces move outside: deleting `b` from `**b c**` gives `**c**`.
- Overlapping marks nest around what they fully contain and inside what crosses the selection.
- `[shortcut]` links: the text is the lookup label, so an edit writes `[new text][old label]`.
- Splitting an autolink or shortcut link gives each half an explicit target.
- Backticks typed in code widen the fence. A pipe in code in a table cell needs `\|`.
- A letter typed right after `**When:**` extends the bold, because CommonMark can't close there.
- Bare URLs aren't structure: typing can start, extend, or end one.

**Blocks:**

- Markdown has no empty paragraph. After Enter at the end of a block, the empty line exists only as a caret position (`pending`) until text arrives.
- An empty list item can't interrupt a paragraph (`- a` then `  - ` is a setext heading), so nesting rules matter.
- Headings can touch neighbouring text and paragraphs can't, so removing a heading may have to add blank lines. The same goes for splitting a heading or lifting a list item.
- Ordered lists renumber only if already sequential; all-`1.` lists stay that way.
- Indented code depends on each line's own indent, not the container prefix.
- Line endings follow the surrounding text, so CRLF files stay CRLF.

**Security:** a document's raw HTML could carry fake `data-src` attributes and steer edits, so offsets and `contenteditable` are stripped from raw HTML after sanitizing.

## Performance

Median 1.6 ms per edit across the fuzz corpus, and 1.4 ms from key event to Swift finishing on small test documents. The second figure stops before the page repaints.

Keystroke cost in a release build, in mid-file. "Quiet" was measured on an idle Mac, "busy" on the final code with other apps loading the machine (load average about 6). A control run of an earlier commit under the same load was just as slow, so the difference is the machine, not a regression.

| File size | Keystroke, quiet | Keystroke, busy | Full render, quiet | Full render, busy |
|---|---|---|---|---|
| 4 KB | 0.9 ms | 1.9 ms | 0.5 ms | 1.1 ms |
| 12 KB | 3.7 ms | 7.6 ms | 1.4 ms | 3.0 ms |
| 27 KB | 9.0 ms | 19 ms | 3.4 ms | 7 ms |
| 91 KB | 27 ms | 54 to 98 ms | 10 ms | 20 to 34 ms |
| 850 KB | 230 ms | 490 ms | 86 ms | 176 ms |

READMEs are fine. Large changelogs aren't: at 850 KB each keystroke costs 300 to 650 ms before the DOM is updated, and 91 KB files can already feel slow on a busy machine. Time grows linearly because each edit re-parses the file at least twice. Verifying only the edited top-level block and its neighbours, with a full check when idle, should fix this, but it hasn't been tried. Treat it as required work for M3. The spike also replaces the whole DOM on every edit; Spike 4 covers that.

## Known limits

Product decisions may be needed on the first two.

- **Rendered typing is always literal.** Typing `# ` or pasting `**x**` gives literal text, not a heading or bold. Markdown auto-formatting would be a new feature. Decide whether pasted Markdown should be parsed.
- **What a refused edit looks like isn't decided.** Today nothing happens. It needs at least a beep.
- **You can't type past the end of bold at the end of a block.** The DOM has no caret position there, so typing extends the bold.
- **Cmd-B with nothing selected does nothing.** There's no "type in bold from here" mode.
- **Blank lines stay behind** if you press Enter at the end of a block and then click away.
- **Marks can't cross blocks.** Selections across a table or code block can't be deleted.
- **Inline HTML shows as raw chips.** HTML blocks can't be edited in the rendered pane (M6).
- **A hard break at the very end of a paragraph is refused.** Markdown has no such thing.
- **YAML front matter still parses as a rule and a heading** (from Spike 1).
- **A block containing a NUL byte is read-only.**
- **Swift traps can't be caught.** An out-of-range bug crashes the app and could lose unsaved work. The fuzzer found one such crash. Keep fuzzing in CI, and make sure autosave or recovery is in place before this ships.

## Not verified

- **A person typing.** Every key and mouse event was synthesized in an invisible window that reports itself as key, with the app not active. Real focus, activation and key-repeat behavior may differ, as with Shift-Enter.
- **IME, and undo in the web view** (Spike 5). The engine's undo is covered; Cmd-Z in the web view is not. `beforeinput` for composition is simply passed through today.
- **Real clipboard.** Paste used a synthetic `ClipboardEvent`, to avoid touching your clipboard. Cut (Cmd-X) wasn't run, and copy from the rendered pane isn't implemented. Rich paste used generated HTML, not real output from Safari, Word or Google Docs.
- **Heading and strikethrough commands** were called directly, as a menu would. Cmd-B, Cmd-I and Cmd-E went through key events.
- **Spell check and autocorrect** (`insertReplacementText` is handled but wasn't exercised), and **drag and drop**, which is ignored.
- **Vertical navigation, RTL text, and screen readers.**
- **Non-UTF-8 files** through the editor. Spike 2's codec would decode them first, so ranges would apply to decoded text, but the two haven't been joined.

## Go/no-go

**GO.** The spike passes its bar using `beforeinput` interception with Swift-side commands, which was the plan's expected approach. No ProseMirror-style fallback is needed, and there's no reduction in scope.

Next: Spikes 4 and 5 can start from this prototype. Spike 4 should replace the full DOM rebuild. M3 needs the incremental re-parse. For the core package, `Parser.swift` should take the anchorer, `BlockSerializer.swift` the writer and attempts, and `HTMLRenderer.swift` the renderer, all rewritten rather than copied, with this spike's scenarios and fuzzer moved into `Tests/`.

## Running it

```bash
cd spikes/spike3-patches && swift test
```

```bash
cd spikes/spike3-patches && swift run spike3-host
```

```bash
cd spikes/spike3-patches && swift run -c release spike3-corpus --fuzz 40 1 ../../Tests/Fixtures/*
```

`spike3-corpus <files>` runs the round-trip check, and `--timing <files>` measures keystrokes. Check the exit code as well as the summary: a crash leaves no summary at all.
