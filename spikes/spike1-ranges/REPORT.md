# Spike 1 report: source ranges on inline elements

**Result: PARTIAL PASS. Continue with `swift-markdown`, and patch inline ranges with a small re-anchoring scanner.**

Block ranges are reliable, and the hard cases (CRLF, tabs, emoji, CJK, combining marks, nested emphasis, escapes, inline code with backticks, reference links, autolinks, fences, tables) all pass. Inline ranges are exact for about 98.5% of nodes in real files. The rest are wrong for a few predictable reasons, all from cmark-gfm, which swift-markdown wraps. Switching to cmark-gfm `sourcepos` directly would give the same numbers with the same bugs, so it isn't an option.

Date: 2026-11-03. swift-markdown 0.9.0 (swift-cmark `gfm` branch), Swift 6.3.3, macOS 26.5.2. Throwaway code.

## What was built

`spike1-ranges`, a command-line tool:

- `dump <file>` prints every node with its range, its UTF-8 and UTF-16 offsets, and the exact source slice.
- `check <file>...` prints a pass/fail table by node type and groups failures by cause.
- `--smart` turns smart punctuation back on (swift-markdown's default). `--keep-bom` leaves the BOM in the parsed text.

`LineIndex.swift` converts swift-markdown's `(line, column)` locations to absolute offsets. `Expectations.swift` states what each node's slice must look like (for example, a Strong node starts and ends with `**` or `__`). Each node is also checked to sit inside its parent and not overlap its siblings.

```bash
cd spikes/spike1-ranges && swift build && .build/debug/spike1-ranges check fixtures/*.md
```

## Columns are UTF-8 byte offsets

Columns are **1-based UTF-8 byte offsets within the line**. Lines split on LF, CRLF, and lone CR. End locations are exclusive (swift-markdown adds 1 to cmark's inclusive end).

Evidence from `fixtures/multibyte.md`: the heading `# 标题 🚀 *強調*` spans columns 1 to 23. That is 22 UTF-8 bytes but 12 UTF-16 units and 10 characters. `**粗体 🎉 字**` sits at UTF-8 31..<50, which is UTF-16 17..<28. Across all 274,174 nodes in the real-world corpus, no range ever split a multi-byte character except where a known bug had already shifted it. Tabs count as one byte and are never expanded.

**Recommended range unit for `Patch` and `data-src`: UTF-16 code units into the decoded text.** Both panes produce UTF-16 offsets natively: `NSRange` in `NSTextView`, and DOM text offsets in JavaScript. With UTF-16 as the unit, only the parser adapter has to convert, once per parse, through a line index like `LineIndex.swift`. This is a shared-contract decision, so it needs the Coordinator's approval (`AGENTS.md` section 3). Spike 3 should confirm it.

## Results

Wrong = the range doesn't point at the node's source. Known deviation = predictable and correctable (see below).

| Corpus | Files | Nodes | Exact | Known deviation | Wrong |
|---|---|---|---|---|---|
| Hard cases (`fixtures/`) | 13 | 331 | 310 | 9 | 12 (3.6%), all from bugs 1, 3, 4 and 7 below |
| CommonMark + GFM spec and regression examples | 728 | 3,620 | 3,301 | 166 | 153 (4.2%), mostly deliberate edge cases |
| Real-world docs (Homebrew docs, npm docs, Swift and C library READMEs on this Mac, swift-markdown docs, `Tests/Fixtures`) | about 420 | 274,174 | 242,966 | 26,965 | 4,243 (1.5%) |

The real-world files were read in place and not committed. Their licenses vary.

Real-world results by node type:

| Node type | Count | Exact | Known deviation | Wrong | Pass? |
|---|---|---|---|---|---|
| Heading | 6,611 | 6,571 | 0 | 40 | Pass except bug 5 |
| Paragraph | 41,570 | 41,541 | 0 | 29 | Pass except bug 5 |
| ListItem / UnorderedList / OrderedList | 27,922 | 27,918 | 0 | 4 | Pass |
| BlockQuote | 90 | 90 | 0 | 0 | Pass |
| CodeBlock (fenced and indented) | 2,485 | 2,481 | 0 | 4 | Pass |
| ThematicBreak | 202 | 202 | 0 | 0 | Pass |
| HTMLBlock | 439 | 390 | 41 | 8 | Pass (range starts after indentation) |
| Table / Head / Body / Row | 1,664 | 1,656 | 0 | 8 | Pass |
| Table.Cell | 4,523 | 4,088 | 6 | 429 | **Fail**: bugs 3 and 4 |
| Text | 112,608 | 109,535 | 208 | 2,865 | **Fail**: bugs 1 and 2 |
| Emphasis | 4,011 | 3,936 | 0 | 75 | **Fail**: bugs 1 and 2 |
| Strong | 2,303 | 2,302 | 0 | 1 | Pass |
| Strikethrough | 1 | 0 | 0 | 1 | Bug 2 |
| InlineCode | 22,067 | 21,482 | 0 | 585 | **Fail**: bug 2 |
| Link | 18,063 | 17,903 | 0 | 160 | **Fail**: bugs 1 and 2 |
| Image | 564 | 535 | 0 | 29 | **Fail**: bug 1 |
| InlineHTML | 2,341 | 2,336 | 0 | 5 | Bug 2 |
| SoftBreak / LineBreak | 26,710 | 0 | 26,710 | 0 | No range at all (deviation A) |

## Bugs (wrong ranges)

All reproduce with a few lines of input:

1. **Line numbers lag after a newline inside an inline construct.** If a paragraph contains a backslash hard break (`foo\` then newline) or a link whose destination or title starts on the next line (`[a](` then newline, `http://x)`), every inline after the *next* line break reports a line number one too small. Columns stay correct, so the error is a whole line, and it grows by one for each such construct. Badge rows in READMEs often trigger this (`fmt` README: 30 links off).
2. **Continuation lines with different indentation shift columns.** In a lazy continuation line (an unindented line continuing a list item or quote), or a paragraph continuation line with extra leading spaces, inline columns are off by the indentation cmark stripped or assumed. For example, `- item` then `lazy *em*` reports `*em*` two bytes late. This is the largest cause in real files (Homebrew's man page, changelogs, docs with hand-wrapped list items).
3. **An escaped pipe in a table cell shifts the cell's inline ranges.** GFM unescapes `\|` before parsing the cell's inlines, so every inline after it is one byte short per escaped pipe. The cell's own range is right.
4. **An empty table cell's range includes the closing `|`.** For `|   |`, the range is `"   |"`. Cells with content are correct.
5. **A setext heading followed directly by a paragraph line swallows that line.** For `Foo`, `---`, `bar`, the Heading range covers all three lines and overlaps the paragraph. This is the only block-level bug. With a blank line after the underline, the range is correct.
6. **A NUL byte shifts the rest of its line by 2.** cmark replaces U+0000 with U+FFFD (3 bytes) before computing columns. Rare in real files.
7. **Smart punctuation is on by default.** With it on, `Text.string` contains curly quotes and dashes that aren't in the source. Ranges are fine, but text-to-source mapping breaks. Always parse with `.disableSmartOpts`, which every result above uses. The renderer must then show straight quotes, which is right for a developer tool anyway.

## Known deviations (predictable, easy to correct)

- **A. SoftBreak and LineBreak have no range.** Derive it from neighbours: the source between the previous sibling's end and the next sibling's start (trailing spaces or `\`, then the line ending, then the next line's indentation or container prefix).
- **B. A Text node right before a line break includes the trailing spaces** that cmark drops from `Text.string`. The text is a prefix of the slice. The extra spaces are the hard-break marker or ignorable whitespace.
- **C. An HTMLBlock's range starts after its leading indentation**, while `rawHTML` includes it.
- **D. Padding cells** that GFM adds to short table rows have no range. They aren't in the source.
- **E. A BOM left in the parsed string** is skipped by cmark but counted in columns, so offsets stay right either way. The Spike 2 codec strips the BOM first.

## Other findings

- **YAML front matter isn't recognized.** The opening `---` parses as a thematic break, and the front matter plus the closing `---` becomes a setext heading. Prompt files often have front matter. The front-matter *features* are in the "Later" tier, but showing it as a giant heading is a bug. M2 should detect front matter, parse only the text after it, offset all ranges by its length, and render it as a plain block.
- **Kramdown-style attribute lines** (`{:toc}`, `{:.class}`) are plain text to cmark. That's fine, and nothing to do.

## Recommendation

**Continue with `swift-markdown` as is for parsing and block ranges, and add an inline re-anchoring pass in `Parser.swift` (MarklightCore).**

- Block ranges: trust them. Clamp setext headings to their underline line (bug 5). Compute HTMLBlock indentation (deviation C).
- Inline ranges: for each leaf block (paragraph, heading, table cell), walk its inline children in order with a cursor over the block's source slice. Accept cmark's offset when the slice passes the same shape checks this spike uses (`Expectations.swift`). Otherwise search forward from the cursor for the expected opening (delimiters, or the text with escapes and entities resolved). Then derive break ranges (deviation A) and trim trailing whitespace (deviation B). This fixes bugs 1 to 4 and 6 without changing the parser, and the checker in this spike becomes its test oracle. Estimated size: a few hundred lines plus golden tests.
- Rendering only needs `data-src` on block elements. Spike 3's fast path needs exact inline ranges only inside the block being edited, so the re-anchoring can run per block, on demand.
- Optional: report bugs 1, 2 and 5 upstream to swift-cmark. Don't wait on a fix.

## Not verified

- Block directives, symbol links, and Doxygen commands (swift-markdown options Marklight won't enable).
- Footnotes: swift-markdown doesn't produce footnote nodes. The text stays inline text. Rendering footnotes would need its own handling.
- Performance of parsing plus re-anchoring. One rough data point: the full parse and check of the largest real file, OpenSSL's 870 KB `CHANGES.md`, took 0.5 s in a debug build. Parsing alone wasn't timed separately.
- Non-UTF-8 files: the checker skips them. Spike 2's codec decodes them first, and ranges then refer to the decoded text.
