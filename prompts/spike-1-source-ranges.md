# Prompt: Spike 1, source ranges on inline elements

Read `CLAUDE.md` and section 4 (Spike 1) of `docs/plan.md`. This is a throwaway spike. Put it in `spikes/spike1-ranges/`, not in the core package.

**Question:** Can `swift-markdown` locate every inline element precisely in the source?

**Build:** A command-line tool that takes a Markdown file path, parses it with `swift-markdown`, walks every AST node, and prints for each node: its type, its reported range, and the exact source slice that range points to.

**Requirements:**

- Work from the file's raw bytes. Determine whether reported columns are UTF-8 byte offsets or characters, and state which, with evidence.
- Include a checker mode that reports any node whose slice does not exactly equal what you expect (for example, a Strong node's slice should start and end with the emphasis markers).
- Run it against every file in `Tests/Fixtures/` and against a set of hard cases you create: nested emphasis, escaped characters, hard breaks, CRLF files, tabs, emoji, CJK, tables, fenced code, links, images, reference links, autolinks, and inline code containing backticks.

**Pass criteria:**

- Slices exactly match the node's source text for headings, paragraphs, lists, emphasis, strong, inline code, links, images, tables, and fences.
- All hard cases pass, including CRLF and multi-byte characters.

**Deliverable:** a short report in `spikes/spike1-ranges/REPORT.md` with a table of node types (pass or fail, with examples of failures), the byte-versus-character finding, and a recommendation: continue with `swift-markdown` as-is, patch the gaps with a custom inline scanner, or switch to cmark-gfm sourcepos. Timebox: 1 to 2 days of effort.
