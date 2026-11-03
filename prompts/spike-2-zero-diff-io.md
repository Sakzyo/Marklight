# Prompt: Spike 2, zero-diff file I/O

Read `CLAUDE.md` and section 4 (Spike 2) of `docs/plan.md`. This is a throwaway spike. Put it in `spikes/spike2-io/`.

**Question:** Can opening a file and saving it with no edits be byte-identical?

**Build:** A minimal `NSDocument`-based macOS app (or a command-line harness if the document machinery isn't needed to prove the point) that reads a file, holds its text exactly, and writes it back.

**Requirements:**

- Detect and preserve encoding, BOM, line endings (including mixed), and trailing-newline state.
- Handle invalid UTF-8 without corrupting the file.
- Preserve the executable bit and symlinks. Document what happens with atomic versus in-place writes (inode change) and how file coordination behaves.
- Provide a script that runs open, no-op, save over every file in `Tests/Fixtures/` and compares SHA-256 hashes before and after.

**Pass criteria:** hashes are identical across UTF-8 with and without BOM, UTF-16, CRLF, mixed line endings, no trailing newline, and invalid UTF-8. Executable bit and symlink targets are preserved.

**Fallback if it fails:** hold the raw bytes plus a decoded view, and write back the raw bytes whenever the text is unchanged.

**Deliverable:** `spikes/spike2-io/REPORT.md` with a results table, the write strategy you recommend (atomic or in place) and why, and any cases that need special handling. Timebox: 1 day.
