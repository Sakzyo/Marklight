# Spike 2 report: zero-diff file I/O

**Result: PASS.** Opening a file and saving it with no edits is byte-identical on every fixture. The executable bit and symlinks are kept, provided the app resolves symlinks before saving (see below).

Date: 2026-11-03. Machine: macOS 26.5.2, Swift 6.3.3, Xcode 26.6. Throwaway code. Nothing here is imported by `Sources/` or `App/`.

## What was built

A command-line harness (`swift build`, product `spike2-io`) rather than a full app. Opening and saving don't need the app's document UI, but the harness still exercises the real AppKit pieces:

- `TextCodec.swift`: decodes the raw bytes into a `String` and records the encoding and BOM, then encodes the text back to bytes.
- `throughTextView`: passes the text through a TextKit 2 `NSTextView` (`view.string = text`, then reads it back), which is what the source pane will hold.
- `SaveStrategy.swift`: five ways to write the file, plus a file-system matrix.
- `run.sh`: copies every fixture to a temp folder, runs open, no-op, save on each copy, and compares SHA-256 hashes and file modes before and after. It also checks a symlink and a `0755` file.

Run it with:

```bash
spikes/spike2-io/run.sh
```

```bash
spikes/spike2-io/.build/debug/spike2-io roundtrip spikes/spike2-io/fixtures/* Tests/Fixtures/*
```

```bash
spikes/spike2-io/.build/debug/spike2-io fs
```

## Results: open, no-op, save

`run.sh`: all 21 files identical, including a symlink saved by its link path. PASS.

| File | Bytes | Detected | Survives NSTextView | Model round-trip | Insert at end of line 1 is local | Naive Foundation round-trip |
|---|---|---|---|---|---|---|
| crlf.md | 30 | utf8 | yes | identical | yes | identical |
| empty.md | 0 | utf8 | yes | identical | yes | identical |
| invalid-utf8.md | 62 | utf8Escaped | yes | identical | yes | fails to open |
| latin1.md | 22 | utf8Escaped | yes | identical | yes | fails to open |
| lone-cr.md | 35 | utf8 | yes | identical | yes | identical |
| many-trailing-newlines.md | 29 | utf8 | yes | identical | yes | identical |
| mixed-endings.md | 41 | utf8 | yes | identical | yes | identical |
| nfd-nfc.md | 46 | utf8 | yes | identical | yes | identical |
| no-trailing-newline.md | 32 | utf8 | yes | identical | yes | identical |
| utf16be-bom.md | 64 | utf16BE+BOM | yes | identical | yes | **changed** (rewritten as another UTF-16 byte order) |
| utf16le-bom.md | 64 | utf16LE+BOM | yes | identical | yes | identical |
| utf16le-nobom.md | 62 | utf16LE | yes | identical | yes | fails to open |
| utf8-bom.md | 22 | utf8+BOM | yes | identical | yes | **changed** (BOM dropped, 22 → 19 bytes) |
| utf8.md | 29 | utf8 | yes | identical | yes | identical |
| whitespace-only.md | 8 | utf8 | yes | identical | yes | identical |
| zero-width-rtl.md | 64 | utf8 | yes | identical | yes | identical |
| Tests/Fixtures/crlf.md | 98 | utf8 | yes | identical | yes | identical |
| Tests/Fixtures/emoji-cjk.md | 291 | utf8 | yes | identical | yes | identical |
| Tests/Fixtures/no-trailing-newline.md | 63 | utf8 | yes | identical | yes | identical |
| Tests/Fixtures/utf8-bom.md | 80 | utf8+BOM | yes | identical | yes | **changed** (BOM dropped) |

"Naive Foundation" means `String(contentsOf:usedEncoding:)` followed by `write(to:atomically:encoding:)`. It is the obvious implementation, and it breaks three of the cases above and fails to open three more. Marklight must not use it.

## Results: write strategies

The test file is `real/doc.md`: mode `0755`, a custom xattr, and a hard link `real/hard.md`. `link.md` is a relative symlink to it. Each strategy saves new content, once by the real path and once by the link path.

| Strategy | Opened via | Symlink kept | Target updated | Inode kept | Mode 0755 kept | xattr kept | Hard link sees edit |
|---|---|---|---|---|---|---|---|
| `Data.write(.atomic)` | real path | n/a | yes | no | **no** | **no** | no |
| `Data.write(.atomic)` | link | **no**, replaced by a regular file | **no** | yes | yes | yes | no |
| In place (truncate + write) | real path | n/a | yes | yes | yes | yes | yes |
| In place (truncate + write) | link | yes | yes | yes | yes | yes | yes |
| Resolve symlink, `Data.write(.atomic)` | link | yes | yes | no | **no** | **no** | no |
| Resolve symlink, temp file + `FileManager.replaceItemAt` | real path | n/a | yes | no | yes | yes | no |
| Resolve symlink, temp file + `FileManager.replaceItemAt` | link | yes | yes | no | yes | yes | no |
| `NSDocument.writeSafely(.saveOperation)` | real path | n/a | yes | no | yes | yes | no |
| `NSDocument.writeSafely(.saveOperation)` | link | yes | **no**: save fails with `NSFileNoSuchFileError` (4) | | | | |

Notes:

- **NSDocument can't save through a symlink.** Relative and absolute symlinks both fail, through `writeSafely` and through `save(to:ofType:for:completionHandler:)`. The original file is left untouched, so nothing is lost, but the save fails. `NSDocument(contentsOf: link)` keeps the link path as `fileURL`, so the app must resolve it itself.
- **Plain atomic writes are the worst choice.** They drop the executable bit and xattrs, and they replace a symlink with a regular file.
- **Safe save (temp file + replace) keeps mode and xattrs but always changes the inode**, which breaks hard links. Editors handle this the same way (vim's `backupcopy=auto` falls back to in-place writes for hard-linked files).
- **In-place writes keep everything** but aren't crash-safe. A crash halfway through leaves a truncated file.

## Recommendations

### Encoding model

Hold `text: String` plus `encoding` and `hasBOM`, and encode back with exactly those settings. Detection order:

1. A BOM (UTF-8, UTF-16 LE or BE): strip it and remember it.
2. BOM-less UTF-16: zero bytes at regular odd or even positions. This has to come before the UTF-8 check, because NUL is valid UTF-8.
3. Strict UTF-8.
4. **Escaped UTF-8** for anything else (invalid bytes, Latin-1). Each invalid byte becomes a private-use scalar, U+10FF80 to U+10FFFF (U+10FF00 + byte), and goes back to the same byte on save. The file stays editable, and the bad bytes survive edits elsewhere. If the file already contains scalars from that range, decoding fails and the file opens read-only with its raw bytes kept (the fallback named in the plan). No fixture needed that.

Line endings need no special handling. CRLF, lone CR, and mixed endings all survive `String` and `NSTextView` unchanged, because nothing normalizes them. Never normalize on load. When writing new line breaks (Enter in either pane), use the file's main line ending. Detecting it is a small follow-up for M1.

### Comparing text

**Never use `==` on `String` to decide whether text changed.** Swift's `==` uses canonical equivalence, so `"\u{E9}" == "e\u{301}"` is `true` (checked). An edit that only changes the Unicode normalization would look like no change at all. Compare UTF-8 bytes instead (`a.utf8.elementsEqual(b.utf8)`). The same rule applies to the semantic no-op check in the block serializer.

### Write strategy

**Recommended: NSDocument safe save on the resolved target, with an in-place fallback for hard links.**

1. At open, resolve symlinks. Use the resolved URL as the `NSDocument` `fileURL`. If the window title should show the link's name, keep that name separately.
2. Save with NSDocument's normal safe save (temp file + replace). It keeps mode and xattrs, and a crash can't leave a half-written file.
3. If the target's link count is above 1, override `writeSafely` to write in place, so every hard link sees the edit.
4. If the buffer is unchanged since open (compared by UTF-8 bytes), write back the original raw bytes. This costs nothing and guards against encoder bugs.

The inode changes on every safe save. That is fine for git and for path-based watchers. How NSDocument's file presenter behaves across its own saves needs the running app, so it's listed under "Not verified".

## Cases that need special handling

- **Symlinks**: resolve at open (see above).
- **Hard links**: write in place.
- **Escaped bytes**: show them as a visible placeholder glyph in both panes, and offer "Reopen with encoding…" (for example Latin-1) instead of guessing. Encodings beyond UTF-8 and UTF-16 aren't detected automatically.
- **BOM-less UTF-16** is detected by a heuristic. A UTF-16 file made mostly of CJK has few zero bytes and won't be detected. It then falls through to escaped UTF-8, which still round-trips byte for byte but shows unreadable text. That's acceptable for v1.
- **A BOM in the middle of the file** (U+FEFF, in `zero-width-rtl.md`) is ordinary text and is kept as is.
- **UTF-32** isn't handled (no BOM sniffing). Add it if a real file turns up.

## Not verified

- A real `NSDocumentController` open from Finder or the Open panel. The harness creates `NSDocument` directly, so whether AppKit resolves symlinks before handing over the URL is unknown. Resolving them ourselves is safe either way.
- Read-only files (mode `0444`) and files in folders we can't write to: NSDocument's save-error UI needs the running app.
- External-change detection via `NSFilePresenter` (for example a git checkout while the file is open). That's M1 work in a real app.
- Network volumes, iCloud Drive, and FAT/exFAT volumes (no xattrs, different replace behavior).
- ACLs and Finder tags beyond the one custom xattr tested.
