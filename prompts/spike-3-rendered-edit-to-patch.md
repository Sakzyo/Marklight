# Prompt: Spike 3, rendered edit to source patch (largest risk)

Read `CLAUDE.md` and section 4 (Spike 3) of `docs/plan.md`. Complete Spike 1 first, since this depends on its findings about source ranges. This is a throwaway spike. Put it in `spikes/spike3-patches/`.

**Question:** Can edits in a `contenteditable` DOM become minimal, correct patches against the Markdown source?

**Build:**

1. A Swift renderer that walks the `swift-markdown` AST and emits HTML with `data-src="start:end"` on every element.
2. A `WKWebView` host that loads that HTML in a `contenteditable` container.
3. JS that intercepts `beforeinput`, calls `preventDefault`, and sends a structured message to Swift (input type, selection mapped to source offsets, data).
4. Swift code that turns each message into a `Patch(range, replacement, origin)`, applies it to the buffer, re-parses, and re-renders.

**Test scenarios (script about 30):** typing mid-word, typing at a text-run boundary, deleting across inline boundaries, deleting a whole word, Enter in a paragraph, Enter in a list item, Enter on an empty list item, Backspace at the start of a list item, Enter and Backspace in a block quote, toggling bold over a partial selection, toggling italic and inline code, changing a heading level, pasting plain text, pasting rich text, clicking a task checkbox, editing a table cell, and cases containing emoji and CJK.

**Pass criteria:** for every scenario, the resulting source differs from the original only in the expected range (assert it), the document re-parses to the expected structure, and untouched text stays byte-identical.

**Fallbacks if it struggles:**

- Route all structural edits through Swift-side commands that you fully control (this is the expected approach).
- Or use a ProseMirror- or CodeMirror-style editor model with the DOM as output only.

**Deliverable:** `spikes/spike3-patches/REPORT.md` with a table of scenarios (pass or fail), a list of edit types that needed special handling, and a clear go or no-go against the rule in `CLAUDE.md`. If it is a no-go, state the reduced product scope. Timebox: 1 to 1.5 weeks of effort.
