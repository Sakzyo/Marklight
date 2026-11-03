# Marklight Kit

Everything needed to start building **Marklight**, the native macOS Markdown reader and editor, with Claude.

## Contents

| File | Purpose |
|---|---|
| `CLAUDE.md` | Project context and working rules. Put this at the repo root so Claude Code reads it automatically. |
| `AGENTS.md` | Multi-agent working guide: roles, ownership, shared contracts, task dependencies, branching, definition of done, handoffs. |
| `docs/plan.md` | Product brief, technical design, distribution notes, spike plan, open items. |
| `docs/test-corpus.md` | What to put in the golden-file test corpus. |
| `docs/decisions.md` | One-line log of every decision made during brainstorming. |
| `prompts/spike-1-source-ranges.md` | Prompt for Spike 1. |
| `prompts/spike-2-zero-diff-io.md` | Prompt for Spike 2. |
| `prompts/spike-3-rendered-edit-to-patch.md` | Prompt for Spike 3. |
| `prompts/spike-4-caret-stability.md` | Prompt for Spike 4. |
| `prompts/spike-5-ime-and-undo.md` | Prompt for Spike 5. |
| `prompts/spike-6-preview-security.md` | Prompt for Spike 6. |
| `prompts/scaffold-repo.md` | Prompt to scaffold the Swift package and repo. |

## How to use it

1. Create the repo, then copy `CLAUDE.md` to its root and the `docs/` folder alongside it.
2. Assemble the test corpus described in `docs/test-corpus.md`.
3. Open the repo in Claude Code and paste `prompts/scaffold-repo.md`.
4. Run the spikes in this order: 2 and 1, then 6, then 3, 4, and 5 together. Paste each prompt from `prompts/` as its own session.
5. Record each spike's result (pass, fail, fallback taken) in `docs/decisions.md` before moving on.
6. Apply the go/no-go rule after Spike 3, then start milestone M1.

If you run several agents in parallel, read `AGENTS.md` first. It sets out who owns what, which spikes can run together, and how to hand work off.

## Before you start

Resolve the open items at the end of `docs/plan.md`, especially the name-conflict check (Inkdown was dropped because an existing Markdown editor uses it; a Swift library called Marklight also exists), the minimum macOS version, and the Sparkle key pair.
