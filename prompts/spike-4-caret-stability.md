# Prompt: Spike 4, caret and scroll stability under DOM patching

Read `CLAUDE.md` and section 4 (Spike 4) of `docs/plan.md`. This extends the Spike 3 prototype. Put it in `spikes/spike4-stability/`.

**Question:** When one pane edits the buffer, does the other pane update without disturbing the user?

**Build:** Add to the Spike 3 prototype:

1. A morphdom-style DOM patcher that updates only the blocks whose source ranges changed, leaving unchanged DOM nodes untouched.
2. An origin-tagging mechanism so the pane that made an edit doesn't re-render the region being edited.
3. A test harness that simulates edits arriving from the source pane while the rendered pane has focus, and the reverse.

**Pass criteria:**

- A caret in the rendered pane doesn't move when the source pane edits a different block.
- Scroll position doesn't jump on remote updates.
- No flicker or feedback loop at 60 keystrokes per second.
- Re-rendering an unchanged block never replaces its DOM node (verify by node identity).

**Fallback:** suppress remote updates to the focused block and apply them on blur.

**Deliverable:** `spikes/spike4-stability/REPORT.md` with measurements (update latency, nodes replaced per edit), what failed and how it was fixed, and whether the fallback was needed. Timebox: 3 to 4 days.
