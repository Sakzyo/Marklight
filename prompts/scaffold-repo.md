# Prompt: scaffold the repo

Read `CLAUDE.md` and `docs/plan.md` first.

Scaffold the repository for Marklight, the macOS Markdown editor. Use the naming in the Naming section of `CLAUDE.md`. Do not write app features yet.

Create:

1. `Package.swift` for a Swift Package named `MarklightCore` with no UI dependencies, targeting macOS 14, depending on `swift-markdown`. Include a library target `MarklightCore` and a test target `MarklightCoreTests`.
2. `Sources/MarklightCore/` with empty placeholder files for: `Buffer.swift`, `Patch.swift`, `Parser.swift`, `HTMLRenderer.swift`, `BlockSerializer.swift`. Each should contain only a doc comment saying what it will own (see section 2 of `docs/plan.md`).
3. `Tests/MarklightCoreTests/` with a golden-file test harness that loads every file in `Tests/Fixtures/`, runs open, no-op, save through the buffer, and asserts the bytes are identical. It should pass trivially with an empty fixtures folder and a placeholder buffer.
4. `Tests/Fixtures/` containing a few starter files from `docs/test-corpus.md` (UTF-8 with BOM, CRLF, no trailing newline, emoji and CJK).
5. `spikes/` with a short README explaining that spikes are throwaway.
6. `.gitignore` for Swift and Xcode, `LICENSE` (MIT, leave the copyright holder as a placeholder), and `THIRD_PARTY_NOTICES` listing `swift-markdown` (Apache 2.0) with a note to add bundled JS libraries later.

Then run `swift build` and `swift test` and report the results. If the environment can't build Swift, say so and stop after creating the files.

Do not create the macOS app target (`Marklight`) yet. Commit in small steps.
