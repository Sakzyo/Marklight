# CLAUDE.md: Marklight

Project context for Claude Code. Read `docs/plan.md` for the full product brief, technical design, and spike plan. This file is the short version plus working rules.

If more than one agent is working on this repo, also read `AGENTS.md` for roles, file ownership, shared contracts, and handoff rules.

## What we're building

**Marklight** is a native macOS Markdown reader and editor for developers (READMEs, docs, prompt files). One file, two views: syntax-highlighted source and a rendered view. **Both are fully editable**, and an edit in either one updates the other.

## Non-negotiables

1. **Zero-diff guarantee.** Opening and saving a file without edits must produce a byte-identical file. Any edit may change only the text it should. Never regenerate a file from an AST.
2. **One buffer is the only truth.** The Swift-side buffer owns the document. Both panes produce `Patch(range, replacement, origin)` values. Neither pane owns state.
3. **Origin tagging.** The pane that made an edit never re-renders the region being edited.
4. **One undo stack** on the buffer, so Cmd-Z works from either pane.
5. **Preserve file details exactly:** encoding, BOM, line endings, trailing newline, permissions, symlinks.
6. **Treat rendered content as untrusted.** Sanitize HTML (DOMPurify), strict CSP, no scripts from the document, links open in the default browser, minimal JS bridge.

## Stack

- Swift, macOS 14+ (re-check before starting), AppKit with `NSTextView` on TextKit 2 for the source pane.
- `WKWebView` with `contenteditable` for the rendered pane.
- `swift-markdown` (Apache 2.0) for parsing. Swift owns parsing, HTML rendering (with `data-src="start:end"` attributes), and block serialization.
- Bundled offline JS: Mermaid, KaTeX, highlight.js, DOMPurify.
- Local files served through a custom `WKURLSchemeHandler` (for example `mdfile://`), never `file://`.
- Sparkle for updates. Unsigned builds at first (ad-hoc sign in the build script). Unsandboxed for v1.
- MIT license. Keep `THIRD_PARTY_NOTICES` current.

## Repository layout (target)

```
Package.swift                  # core Swift package, no UI dependencies
Sources/MarklightCore/          # buffer, patch bus, parser integration, HTML renderer, block serializer
Tests/MarklightCoreTests/       # golden-file tests
Tests/Fixtures/                # real READMEs and edge-case files (see docs/test-corpus.md)
App/                           # macOS app target (NSDocument, panes, bridge)
Resources/web/                 # bundled JS/CSS for the preview
spikes/                        # throwaway prototypes, kept out of the app target
docs/                          # plan, decisions
```

## Naming

- Product name: **Marklight**. Swift package and module: `MarklightCore` (tests in `MarklightCoreTests`). App target: `Marklight`.
- Suggested repo name: `marklight`. Bundle identifier: placeholder `com.example.Marklight` until the owner sets a real one.
- The custom preview URL scheme in the docs (`mdfile://`) is only an example; pick the final scheme name when implementing Spike 6.
- Use the name consistently in UI strings, build scripts, and docs. Don't invent alternate names.

## Working rules

- Work in the order of the spike plan before writing app code. See `prompts/` for one prompt per spike.
- Spikes are throwaway. Put them in `spikes/`, not in the app or core package.
- Every behavior that touches the file's bytes needs a golden-file test. Open, no-op, save must hash identically.
- Offsets: confirm whether `swift-markdown` columns are UTF-8 byte offsets and convert carefully. Test with emoji and CJK.
- Prefer intercepting `beforeinput` (call `preventDefault`, apply the edit in Swift) over diffing DOM mutations.
- Patch IME composition on `compositionend` only.
- Keep the JS side thin. Swift decides, JS reports events and applies DOM patches.
- Don't add features from the "Later" or "Never" tiers in `docs/plan.md` without asking.
- Ask before adding dependencies beyond those listed.

## Go/no-go rule

If Spike 3 (rendered edit to source patch) can't pass within its timebox using `beforeinput` interception, fall back to: fully editable source pane plus a rendered pane with formatting controls and task-checkbox toggling only. Say so plainly rather than drifting.

## Milestones

M1 source editor and zero-diff I/O, M2 read-only rendered view with source ranges and layouts, M3 patch bus and fast-path typing, M4 structural editing, M5 tables/images/code blocks, M6 Mermaid/math/HTML blocks.

## Commit style

Small commits, one concern each. Run the golden-file suite before committing changes to the buffer, parser, or serializer.
