/// `Patch(range, replacement, origin)`: the single unit of change on the patch bus.
///
/// Both panes express every edit as a patch against the buffer. `origin`
/// identifies the pane that made the edit so it never re-renders the region
/// being edited. Ranges are UTF-16 code units into the decoded text; see
/// `docs/contracts.md`, `docs/plan.md` section 2.1, and `AGENTS.md` section 3.
