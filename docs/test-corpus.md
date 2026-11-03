# Golden-file test corpus

The safety net for the whole project. Put fixtures in `Tests/Fixtures/`. Every fixture is used for the zero-diff test (open, no-op, save, hash must match) and, where relevant, for edit-operation tests.

## Real-world files

Collect 20 to 40 real Markdown files of different shapes:

- Large project READMEs (badges, HTML blocks, tables, nested lists).
- Docs pages with long code blocks in several languages.
- Changelogs (many headings and nested bullets).
- Prompt files (XML-style tags, `{{variables}}`, YAML front matter).
- Files with Mermaid diagrams and math.
- Files with relative images.

Use files with permissive licenses, or your own.

## Synthetic edge cases

| Category | Cases |
|---|---|
| Encoding | UTF-8, UTF-8 with BOM, UTF-16 LE and BE, invalid UTF-8 bytes |
| Line endings | LF, CRLF, mixed, lone CR |
| File endings | No trailing newline, multiple trailing newlines, empty file, whitespace-only file |
| Characters | Emoji, CJK, combining marks, right-to-left text, zero-width characters, tabs |
| Inline | Nested emphasis, escaped characters, hard breaks (two spaces and backslash), inline code with backticks, autolinks, reference links |
| Blocks | Setext headings, indented code, fenced code with `~~~` and with long fences, nested blockquotes, lists with mixed markers, loose and tight lists, numbered lists with non-1 starts |
| GFM | Tables with alignment and escaped pipes, task lists, strikethrough, footnotes |
| HTML | Inline HTML, HTML blocks, comments |
| Metadata | YAML front matter |
| File system | Executable bit, symlink to a Markdown file, read-only file |

## Edit-operation tests (added from Spike 3 onward)

For each edit operation (type mid-word, delete across inline boundaries, Enter in a list, Backspace at list-item start, toggle bold on a partial selection, paste plain and rich text, toggle task checkbox, edit a table cell), assert:

1. The resulting source differs from the original only in the expected range.
2. The result re-parses to the expected structure.
3. Undo restores the original bytes exactly.
