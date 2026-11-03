# AGENTS.md: multi-agent working guide

How several agents (and the human) work on **Marklight** in parallel without colliding. Read `CLAUDE.md` first for the project rules and `docs/plan.md` for the design. This file covers coordination only. If the two disagree, `CLAUDE.md` wins.

## 1. Principles

1. **One owner per area.** Each directory and file has one owning agent at a time. Others read it, and request changes through the owner or the human.
2. **Contracts before code.** Agents that depend on each other agree on an interface first, in writing, then build against it.
3. **Small, reversible steps.** Short-lived branches, small commits, frequent integration.
4. **Evidence over claims.** "Done" means tests ran and results are recorded, not that code was written.
5. **The zero-diff guarantee is everyone's job.** No agent may weaken a golden-file test to make its own work pass.

## 2. Roles

| Role | Owns | Does not touch |
|---|---|---|
| **Coordinator** (human, or one lead agent) | `docs/decisions.md`, task assignment, merge order, go/no-go calls | Feature code |
| **Core agent** | `Sources/MarklightCore/` (buffer, patch bus, undo stack, parser integration) | App UI, web assets |
| **Renderer agent** | `HTMLRenderer.swift`, `BlockSerializer.swift`, `Resources/web/` render and patch logic | Buffer internals |
| **Source-pane agent** | `App/` source editor (`NSTextView`, highlighting, find) | Rendered pane |
| **Preview agent** | `App/` web view host, JS bridge, scheme handler, CSP | Source pane |
| **Test agent** | `Tests/`, `Tests/Fixtures/`, golden-file harness | Production code (reports bugs instead) |
| **Release agent** | Build scripts, ad-hoc signing, Sparkle, `THIRD_PARTY_NOTICES`, README | Feature code |
| **Reviewer agent** | Nothing; reads diffs and reports | Everything (read-only) |

A single agent may hold several roles in small phases. It still follows each role's boundaries, one task at a time.

## 3. Shared contracts

These are the interfaces agents depend on. Changing any of them needs the Coordinator's approval and a note in `docs/decisions.md`.

- **`Patch`**: `Patch(range, replacement, origin)`, where `range` is expressed in a single agreed unit (decide once, in Spike 1: UTF-8 byte offsets or characters) and `origin` identifies the pane.
- **`Buffer` API**: apply a patch, read text and slices, undo and redo, subscribe to changes. Panes only ever talk to the buffer through this API.
- **Render output contract**: every rendered element carries `data-src="start:end"` in the agreed unit.
- **Bridge messages**: the JS-to-Swift message types and fields, documented in `docs/bridge.md` once Spike 3 settles them. Keep the surface minimal.
- **Fixtures**: files in `Tests/Fixtures/` are append-only. Never edit or delete a fixture to make a test pass.

Write each contract down in `docs/` before two agents build against it.

## 4. Task dependencies

```
Spike 2 (I/O)        ─┐
Spike 1 (ranges)     ─┼─> Spike 3 (rendered edit to patch) ─┬─> Spike 4 (caret stability)
Spike 6 (security)   ─┘      (needs Spike 1 findings)        └─> Spike 5 (IME and undo)
```

- Spikes 1, 2, and 6 are independent and can run in parallel immediately.
- Spike 3 starts after Spike 1 reports, because it needs the confirmed range unit and any scanner workarounds.
- Spikes 4 and 5 start after Spike 3 reaches a working prototype. They can run in parallel with each other, each on its own copy of the prototype.
- No milestone work (M1 onward) starts until the go/no-go rule in `CLAUDE.md` has been applied after Spike 3.

## 5. Branches and worktrees

- Each agent works in its own git worktree on its own branch: `agent/<role>/<task>` (for example `agent/core/buffer-undo`).
- Branch from the latest integration branch (`main`). Rebase before opening a merge request.
- Spike branches live under `spikes/` and are never merged into `Sources/` or `App/`. Their output is a `REPORT.md`, plus any fixtures worth keeping.
- Keep branches short-lived: merge or discard within a few days.

## 6. File ownership and conflicts

- Don't edit files outside your role's ownership. If you need a change, write a request in the task thread with the exact change and the reason.
- If two agents need the same file, the Coordinator sequences them: one finishes and merges, then the other starts.
- Never reformat files you don't own. Formatting-only diffs create merge noise and, in this project, can hide real regressions.
- If you hit a merge conflict in code you don't own, stop and ask. Don't resolve it by choosing your side.

## 7. Definition of done

A task is done only when all of these hold:

1. The code builds and the full test suite passes, including the golden-file suite (open, no-op, save is byte-identical).
2. New behavior has tests, and edit operations assert that only the expected source range changed.
3. No test was weakened, skipped, or deleted to get green. If one is legitimately obsolete, say so and get the Coordinator's approval.
4. Security-relevant changes (preview, bridge, scheme handler) were reviewed against section 2.6 of `docs/plan.md`.
5. A handoff note was written (section 8).
6. Anything not verified, such as IME on real input methods or behavior on a real macOS machine, is stated explicitly. Don't claim it works.

## 8. Handoff note format

End every task with a note in the task thread (or `docs/handoffs/<task>.md` for larger work):

```
Task: <name>
Branch: <branch>
Status: done | partial | blocked
What changed: <files and behavior, briefly>
Contracts touched: <none | list>
Tests run: <command and result>
Not verified: <list>
Risks and open questions: <list>
Next step for whoever picks this up: <one line>
```

## 9. Spike reports

Each spike ends with a `REPORT.md` in its folder (see `prompts/`). The Coordinator copies the outcome into the spike table in `docs/decisions.md`: result, fallback taken, date. A spike isn't closed until that row is filled in.

## 10. Review

- The Reviewer agent checks every merge request against: zero-diff impact, contract changes, ownership violations, test integrity, and security rules.
- The author doesn't review its own change.
- Reviewers report findings with file and line references and a severity (blocker, should-fix, nit). Only blockers stop a merge.

## 11. Escalate to the human

Stop and ask rather than guess when:

- A shared contract needs to change.
- A spike fails its pass criteria and a fallback would change product scope.
- Two agents disagree on an approach.
- A task would need a new dependency, a feature from the "Later" or "Never" tier, or weakening a security or zero-diff rule.
- Something needs a real macOS machine, a signing identity, or the Sparkle private key. Agents must never generate, print, or commit the Sparkle private key.
- The same failure repeats after two attempts.

## 12. Suggested first parallel wave

| Agent | Task | Prompt |
|---|---|---|
| Core agent | Scaffold the repo | `prompts/scaffold-repo.md` |
| Test agent | Assemble the fixture corpus | `docs/test-corpus.md` |
| Agent A | Spike 1, source ranges | `prompts/spike-1-source-ranges.md` |
| Agent B | Spike 2, zero-diff I/O | `prompts/spike-2-zero-diff-io.md` |
| Agent C | Spike 6, preview security | `prompts/spike-6-preview-security.md` |

When Spike 1 reports, start Spike 3. When Spike 3 reaches a working prototype, start Spikes 4 and 5 in parallel. Then the Coordinator applies the go/no-go rule.
