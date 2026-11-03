# Prompt: Spike 5, IME composition and unified undo

Read `CLAUDE.md` and section 4 (Spike 5) of `docs/plan.md`. This extends the Spike 3 prototype. Put it in `spikes/spike5-ime-undo/`.

**Question:** Do IME composition input and a unified undo stack work across both panes?

**Build:**

1. Handle `compositionstart`, `compositionupdate`, and `compositionend` in the rendered pane. Don't patch the buffer mid-composition. Patch once on `compositionend`.
2. Move undo into Swift: an undo stack on the buffer, with the web view's native undo disabled. Wire Cmd-Z and Cmd-Shift-Z to it from both panes.
3. Group typing into sensible undo steps (for example, by pause or by word boundary), and make structural edits their own steps.

**Pass criteria:**

- Typing with a Chinese or Japanese IME in the rendered pane works: no duplicated, lost, or reordered text, and the caret ends up in the right place.
- Candidate-window selection and cancelling composition (Escape) behave correctly.
- Cmd-Z undoes the last edit regardless of which pane made it or which pane has focus, and undoing everything returns the original bytes exactly.

**Note:** IME testing needs a real macOS machine with input sources enabled. If the environment can't run the app, write the implementation and a manual test script, and say clearly what was not verified.

**Fallback:** defer all patching until `compositionend` (already assumed), and own undo entirely in Swift.

**Deliverable:** `spikes/spike5-ime-undo/REPORT.md` with results per scenario and anything that was not verified. Timebox: 3 to 4 days. Don't skip the IME half.
