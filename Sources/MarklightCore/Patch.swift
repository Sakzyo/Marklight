/// `Patch(range, replacement, origin)`: the single unit of change on the patch bus.
///
/// Both panes express every edit as a patch against the buffer. `origin`
/// identifies the pane that made the edit so it never re-renders the region
/// being edited. The range unit (UTF-8 bytes or characters) is decided in
/// Spike 1. See `docs/plan.md` section 2.1 and `AGENTS.md` section 3.
