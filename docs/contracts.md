# Shared contracts

Interfaces that more than one agent builds against (see `AGENTS.md` section 3). Changing anything here needs the Coordinator's approval and a line in `docs/decisions.md`.

## Range unit

Approved 2026-11-03.

- Every range on the patch bus and in rendered output is a half-open range of **UTF-16 code units** into the buffer's decoded text: `start..<end`, counted from 0.
- "Decoded text" is the document text after decoding, without the BOM (see `spikes/spike2-io/REPORT.md`). A BOM never takes up an offset.
- A range must never split a surrogate pair. Producers check this; the buffer rejects a patch that does.
- Line endings count as written: CRLF is 2 units, LF and lone CR are 1.
- swift-markdown reports 1-based (line, UTF-8 byte column) locations. Only the parser adapter in `Parser.swift` converts them, through a line index, after the inline range corrections described in `spikes/spike1-ranges/REPORT.md`.

## Patch

`Patch(range, replacement, origin)`

- `range`: as above, against the buffer text before the patch.
- `replacement`: the new text. An empty string means delete; an empty range means insert.
- `origin`: which pane made the edit (source pane, rendered pane, or a command such as undo). The originating pane doesn't re-render the region it is editing.

## Render output

Every rendered element carries `data-src="start:end"` in the range unit above. Elements with no source of their own (for example padding cells GFM adds to short table rows) carry no `data-src`.
