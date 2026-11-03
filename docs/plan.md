# Marklight: Product Brief, Technical Design, and Spike Plan

Status: pre-implementation planning. Date: 2026-11-03.

Contents:

1. Product brief
2. Technical design
3. Distribution and constraints
4. Spike plan
5. Open items

---

# 1. Product brief

## 1.1 Purpose

Marklight is a fast, native macOS app for reading and editing Markdown files. It shows the same file as raw, syntax-highlighted source and as rendered output, and **both views are fully editable**. Edits in either one update the other.

## 1.2 Audience

Developers who write Markdown: READMEs, docs, and prompt files.

Expectations of this audience:

- Fast startup and a light footprint.
- Keyboard-first editing.
- Good code-block handling.
- Clean diffs under git.

## 1.3 Differentiator

Two editable views of one buffer, with a **zero-diff guarantee**: opening and saving a file without changes produces a byte-identical file, and any edit changes only the text it should.

## 1.4 Decisions locked in

| Topic | Decision |
|---|---|
| Reader/editor balance | Equal mix |
| Editing model | Source and rendered panes are both fully editable and stay in sync |
| Rendered-pane editing | Typing, deleting, Enter/Backspace behavior in lists and quotes, formatting shortcuts and toolbar, paste, task-checkbox clicks, table-cell edits |
| Mermaid, math, HTML blocks | Edit-in-place: click to edit the block's source, rendered result shown on blur |
| Zero-diff saves | Hard requirement |
| Document model | Single document (multiple windows allowed), no folder sidebar in v1 |
| Prompt-specific features | Not in the first release |
| Render scope (v1) | Headings, lists, code blocks, GFM tables, task lists, local images, Mermaid, math, HTML blocks |
| License | MIT |
| Source pane | Native `NSTextView` on TextKit 2 |
| Minimum macOS | 14 (Sonoma); re-check against Apple's current lineup before starting |
| Distribution | GitHub Releases, Sparkle updates, unsigned builds at first |
| Sandbox | Unsandboxed for v1 |

## 1.5 Feature triage

| Tier | Items |
|---|---|
| **Must (v1)** | Open/save with zero-diff guarantee; source editor with syntax highlighting; rendered view with the full scope above; toggle and split layouts; editing in both panes; formatting controls; find; undo/redo; light/dark mode; external-change detection; Sparkle updates |
| **Should (v1.x)** | Outline sidebar; export to HTML/PDF; list auto-continuation; custom CSS; synced-scroll polish; recent files and state restoration |
| **Later** | Folder sidebar and quick open; tabs; Quick Look extension; Shortcuts/Services; iCloud polish; prompt-specific features (XML tags, `{{variables}}`, token counts, YAML front matter); drag-reorder blocks; drag-drop images |
| **Never (for now)** | Plugin system; collaboration; built-in publishing; vim mode; database or notes-library model |

The "Never" tier keeps this a sharp developer tool rather than a notes platform.

## 1.6 Non-goals

- Competing with Obsidian or Notion on knowledge management.
- Rewriting or normalizing users' Markdown. The app never reformats text the user didn't touch.

---

# 2. Technical design

## 2.1 Architecture: one buffer, two views, a patch bus

```
   Source pane (NSTextView)          Rendered pane (WKWebView, contenteditable)
            \                                   /
             \--- edits become Patches --------/
                     (range, replacement, origin)
                              |
                    Document buffer (Swift)
                  the only copy of the truth
                              |
                 parse -> AST with source ranges
                              |
            re-highlight source / re-render preview (as DOM patches)
```

- Neither pane owns the document. Every edit becomes a `Patch(range, replacement, origin)` applied to one Swift-side buffer. The other pane updates from that.
- **Origin tagging** prevents feedback loops. The pane that made an edit never re-renders the region being edited, so the caret doesn't jump.
- **One undo stack** lives on the buffer, so Cmd-Z behaves the same whichever pane has focus.

## 2.2 Rendered-pane edits to source patches

Two-tier strategy:

1. **Fast path (plain-text edits).** Typing inside a text run maps to a character offset in the source and becomes a tiny patch.
2. **Block path (structural edits).** Enter in a list, heading-level changes, bold across a selection, and paste are handled per block. Swift re-serializes only that block and replaces only its source range. Other blocks stay untouched.

The preferred mechanism is to **intercept `beforeinput`**, call `preventDefault`, and have Swift apply the edit as a command. This is more predictable than diffing DOM mutations after the fact.

Zero-diff guards:

- **Semantic no-op check.** If the re-parsed edited block equals the original block's AST, keep the original text.
- **Per-file style detection.** Detect bullet marker (`-` vs `*`), emphasis style (`**` vs `__`), fence style, and list numbering. Use those for any newly written Markdown.

## 2.3 Where the Markdown logic lives

**Chosen: Swift owns parsing, rendering, and serialization.**

- Parser: `swift-markdown` (Apache 2.0, built on cmark-gfm), whose AST carries source ranges.
- A small renderer walks the AST and emits HTML with `data-src="start:end"` attributes on each element.
- One parser serves highlighting, rendering, and range mapping, so the panes cannot disagree.

Fallback: JS-side `remark`/`unified` (positions on inline nodes plus a ready-made stringifier). The cost is two parsers that can diverge on edge cases. Use this only if Spike 3 shows the Swift serializer is too costly.

## 2.4 Components

| Piece | Choice |
|---|---|
| Source pane | `NSTextView` on TextKit 2, highlighted from AST ranges (debounced full re-parse is fine for README-sized files; optimize later) |
| Rendered pane | `WKWebView` with `contenteditable`; morphdom-style DOM patching so updates don't destroy the caret |
| Bundled JS (offline) | Mermaid, KaTeX, highlight.js, DOMPurify |
| Bridge | `WKScriptMessageHandler` (JS to Swift), `evaluateJavaScript` (Swift to JS); keep the API surface minimal |
| Document model | `NSDocument` (or SwiftUI `DocumentGroup` with AppKit views inside), holding the buffer as exact text plus detected encoding, BOM, and line endings |
| Local file access | Custom `WKURLSchemeHandler` (for example `mdfile://`) instead of `file://` |

## 2.5 Special blocks

Mermaid, math, and HTML blocks can't be WYSIWYG-edited. In the rendered pane, clicking one swaps it for an editable source view of that block. Clicking away shows the render again. Edits patch the buffer like any other.

## 2.6 Rendered-pane security

The preview renders untrusted content (often from cloned repos).

- Sanitize HTML blocks with DOMPurify.
- Set a strict Content-Security-Policy.
- Allow scripts only from bundled files, never from the document.
- Open links in the default browser, not inside the preview.
- Constrain the bridge API to the minimum.
- Restrict the scheme handler to the document's folder tree (policy to be confirmed in Spike 6).

## 2.7 File handling (protects zero-diff)

- Preserve encoding, BOM, line endings, and trailing newline exactly; cover each with tests.
- Use `NSDocument` file coordination for external-change detection (for example after a git checkout), with a reload-or-keep prompt when the buffer is dirty.
- Preserve file permissions, attributes, and symlinks on save. Be deliberate about atomic writes: atomic replace changes the inode.
- Make autosave a setting, since silent in-place autosave interacts with git and file watchers.

## 2.8 Repository structure

Put the core in a **Swift Package with no UI dependencies**: buffer, patch bus, parser integration, HTML renderer, block serializer. The app target depends on it.

Build a **golden-file test suite** of real READMEs. It asserts that:

- open, no-op, save is byte-identical;
- each edit operation changes only the expected source range.

This suite is the safety net for the whole project.

## 2.9 Milestones

| # | Milestone | Outcome |
|---|---|---|
| M1 | Source editor, highlighting, zero-diff open/save, file handling | Usable source editor |
| M2 | Read-only rendered view with source-range attributes; toggle and split layouts; selection sync | Usable reader and editor |
| M3 | Patch bus and fast-path rendered editing (typing in text runs) | Distinctive core begins |
| M4 | Structural editing: lists, headings, quotes, inline formatting, paste, task checkboxes | Full rendered editing for common content |
| M5 | Tables, images, and code blocks in the rendered pane | Broader coverage |
| M6 | Mermaid, math, and HTML blocks with edit-in-place | Full v1 render scope |

After M2 you have a solid reader and source editor. M3 to M4 are where the product becomes distinctive.

---

# 3. Distribution and constraints

## 3.1 Release plan

1. **GitHub Releases** with a DMG or zip.
2. **Sparkle** auto-updates in v1.
3. **Homebrew.** Check the current official cask policy for unsigned apps before promising a cask; a personal tap is the fallback.
4. **Mac App Store:** optional and later, since it forces sandboxing.

## 3.2 Consequences of unsigned builds

- **Gatekeeper.** On recent macOS versions, users must go to System Settings → Privacy & Security and click "Open Anyway" on first launch. Document this in the README.
- **Apple Silicon.** Binaries must be at least ad-hoc signed. Do this in the build script.
- **Sparkle.** Update integrity comes from its EdDSA key pair, so it works without a Developer ID. Generate the key early, back up the private key safely, and never lose it. Sparkle-downloaded updates aren't quarantined, so only the first launch is awkward.
- **Recommendation:** get a paid Apple Developer ID (signing and notarization) before 1.0. It removes most of this friction.

## 3.3 Sandboxing

Unsandboxed for v1, because relative images (`./docs/screenshot.png`) need sibling-folder access. Serving local files through a custom scheme handler keeps the door open to sandboxing later (folder grant stored as a security-scoped bookmark).

## 3.4 Licensing

MIT for the app. Keep a `THIRD_PARTY_NOTICES` file: `swift-markdown` is Apache 2.0 and requires its notice to be preserved, and each bundled JS library carries its own license.

---

# 4. Spike plan

Throwaway prototypes run before committing to the architecture. Each has a question, a build, pass criteria, a fallback, and a timebox.

**Order:** Spikes 2 and 1 first (about 3 days), then 6, then 3, 4, and 5 together. Total is about 3-4 weeks part-time before real app code.

## Spike 1: Source ranges on inline elements

- **Question:** Can `swift-markdown` locate every inline element precisely?
- **Build:** A command-line tool that parses a corpus of real READMEs and prints, for each AST node, the source slice its range points to.
- **Pass:**
  - Slices exactly equal the node's source text for headings, paragraphs, lists, emphasis, strong, inline code, links, images, tables, and fences.
  - Hard cases pass: nested emphasis, escaped characters, hard breaks, CRLF files, tabs, and multi-byte characters (emoji, CJK).
  - Verify whether columns are UTF-8 byte offsets rather than characters, since offset-conversion bugs are easy to make.
- **Fallback:** Write your own inline scanner for the gaps, or use cmark-gfm directly with its sourcepos output.
- **Timebox:** 1-2 days.

## Spike 2: Zero-diff file I/O

- **Question:** Is open → save with no edits byte-identical?
- **Build:** A minimal `NSDocument` that holds the text exactly and saves it.
- **Pass:** The saved file hashes identically to the original across UTF-8 with and without BOM, UTF-16, CRLF, mixed line endings, no trailing newline, and invalid UTF-8. Executable bit and symlinks are preserved.
- **Fallback:** Hold raw bytes plus a decoded view, and write back the raw bytes when nothing changed.
- **Timebox:** 1 day.

## Spike 3: Rendered edit to source patch (largest risk)

- **Question:** Can edits in a `contenteditable` DOM become minimal, correct patches?
- **Build:** Swift renders HTML with `data-src="start:end"` on elements. The page reports `beforeinput` events to Swift, which applies patches and re-renders.
- **Pass:** About 30 scripted scenarios, including typing mid-word, deleting across inline boundaries, Enter in lists and quotes, Backspace at the start of a list item, bold toggle over a partial selection, and paste of plain and rich text. For each, the source differs from the original only in the expected range, and the file re-parses to the expected structure.
- **Fallback:**
  - Route all structural edits through Swift commands (intercept `beforeinput`, `preventDefault`, apply the edit in Swift). This is the expected winner.
  - Or use a ProseMirror- or CodeMirror-style editor model in the web view, with the DOM as output only.
- **Timebox:** 1-1.5 weeks.

## Spike 4: Caret and scroll stability under DOM patching

- **Question:** When one pane edits, does the other update without disturbing the user?
- **Build:** Spike 3's prototype plus a morphdom-style patcher that updates only changed blocks.
- **Pass:**
  - A caret in the rendered pane doesn't move when the other pane edits a different block.
  - Scroll position doesn't jump.
  - No flicker or feedback loop at 60 keystrokes per second.
  - Re-rendering an unchanged block never touches its DOM node.
- **Fallback:** Suppress remote updates to the focused block and apply them on blur.
- **Timebox:** 3-4 days.

## Spike 5: IME and undo

- **Question:** Do composition input and a unified undo stack work?
- **Build:** Extend the Spike 3 prototype.
- **Pass:**
  - Typing with a Chinese or Japanese IME in the rendered pane works. Composition text is patched on commit only, with nothing duplicated or lost.
  - Cmd-Z undoes the last edit regardless of which pane made it or which has focus.
- **Fallback:** Defer patching until `compositionend`. Own the undo stack in Swift and disable the web view's native undo.
- **Timebox:** 3-4 days. Do not skip the IME half; any Asian-language user will hit it immediately.

## Spike 6: Preview security and local files

- **Question:** Can the preview load relative images safely?
- **Build:** A `WKURLSchemeHandler` serving files relative to the document, plus a strict CSP.
- **Pass:**
  - Relative images load.
  - `../../etc/passwd`-style traversal is blocked (policy: probably the document folder tree only).
  - Scripts embedded in a Markdown file don't run.
  - Links open in the browser, not inside the preview.
- **Timebox:** 1-2 days.

## Go/no-go rule

If Spike 3 can't reach its pass bar within its timebox using `beforeinput` interception, drop to the simpler product: **fully editable source pane plus a rendered pane with formatting controls and task-checkbox toggling**, with free typing in the rendered pane deferred. That is still a good app. Deciding this now prevents drifting into month four before facing it.

---

# 5. Open items

- [ ] Confirm the minimum macOS target (default: 14) against Apple's current release lineup.
- [ ] Check Homebrew's current policy on unsigned casks; plan a personal tap as the fallback.
- [ ] Decide the local-file access policy (document folder tree only, or configurable).
- [ ] Decide the autosave default.
- [x] Project name: Marklight (replaces Inkdown, which is taken by an existing Markdown editor).
- [ ] Check the name for conflicts before publishing. A Swift library called Marklight (macteo/Marklight, a Markdown syntax highlighter) already exists, so check for confusion in Swift Package Manager and CocoaPods, and check trademarks, App Store names, and Homebrew cask names. If it is a problem, pick a distinct variant. Renaming is a find-and-replace on `Marklight` and `MarklightCore`.
- [ ] Choose the GitHub repo name (suggested: `marklight`, subject to the check above).
- [ ] Decide whether to obtain an Apple Developer ID before 1.0 (recommended).
- [ ] Generate the Sparkle EdDSA key pair and back up the private key.
- [ ] Assemble the golden-file test corpus (real READMEs with varied encodings, line endings, and Markdown features).

## Suggested next step

Run Spike 1 first. Scaffold the Swift package, assemble the test corpus, and start with the source-range printer.
