# M3 rendered typing

| Handoff | Detail |
|---|---|
| Task | Verified rendered typing and deletion within one editable leaf |
| Branch | `agent/core/m3-rendered-typing`, based on merged M2 at `9957cd0` |
| Status | Partial. Functional suites passed. Native key-to-DOM latency at 850 KB exceeded the 50 ms target. |
| Contracts touched | None. The app uses the approved UTF-16 ranges and bridge messages. |
| Next step | Review the 850 KB native delivery delay before extending performance work. The owner’s real-IME steps are in `docs/m3-manual-ime.md`. |

## What changed

- The rendered editor keeps a snapshot of parsed top-level blocks. It reparses the edited block and its neighbours, checks that both outer guards still match, and shifts later offsets. Ambiguous boundaries, grammar changes, or unresolved reference context trigger full verification before commit. An idle check compares the same revision with a full parse. A mismatch logs the revision and rebuilds the page from the full result.
- Ordinary standalone reference definitions can supply context for a local parse. The fast path preserves definition order and conservatively bounds cmark’s expansion quota. Complex or unusually large definition sets still use the full path.
- The serializer changes one leaf’s atoms, checks the resulting structure, and returns one minimal source patch. Tests cover the exact edit position among repeated characters, literal Markdown punctuation, unchanged delimiter and entity spellings, and undo to original bytes. A deletion that would also discard unselected leading whitespace is refused.
- Swift verifies input on a serial worker and commits against the current buffer version. A local edit skips the source-typing delay. The renderer sends the changed block directly. The page queues navigation and further input until Swift acknowledges the DOM update. Verification rebases against intervening edits, refusing overlaps that would overwrite newly inserted text. Menu commands and WebKit history events both use the documented `undo` message so history stays ordered with outstanding typing.
- The page accepts text in paragraphs, headings, quotes and list items. Raw HTML, tables, code blocks, images and other protected content stay read-only. Plain clicks place the caret. Cmd-click uses the native routing policy. Unsupported operations beep. The source pane retains its selection and scroll, and a patch that cannot fit its storage resynchronizes from the buffer.
- IME edits preserve the original marked range. Swift receives a single edit on commit. Cancellation and full loads reconcile WebKit’s transient DOM. Undo/redo restores an actual pending paragraph so it can be typed into again.

## Evidence

Tests ran on macOS 26.5.2, Xcode 26.6 and Swift 6.3.3. The starting core and app suites exited 0 with 81 tests in 5 suites and 100 tests in 7 suites respectively. The timing suite was skipped for the debug baseline.

The parser differential used 5,800 seeded patches on the fixture corpus. It compares block kinds, source ranges, atom units and ranges, mark grouping and delimiter bytes, inline trees, and HTML/table metadata. Removing the reference-context fallback produced nine atoms for a distant link where the full parse produced two. Removing the reference-expansion quota bound exposed a different distant link mismatch. An app test injects a divergent cached tree and observes a fresh load at the same buffer version.

The large engine fuzzer counted the following attempted operations. The caret samples include leaf edges and empty target ranges.

| Operation | Applied | Refused | Refusal rate |
|---|---:|---:|---:|
| Letter | 604 | 0 | 0% |
| Literal punctuation or Unicode | 585 | 16 | 2.7% |
| Backspace | 479 | 156 | 24.6% |
| Forward delete | 447 | 161 | 26.5% |
| Replace selection | 556 | 12 | 2.1% |
| Word delete | 227 | 370 | 62.0% |
| Line delete | 188 | 359 | 65.6% |

Of the Backspace and forward-delete refusals, 146 and 151 occurred at a leaf edge. Of the word and line refusals, 364 and 348 had empty browser targets. These sampled rates are not a measure of the frequency of refusals in human typing. Emptying a paragraph, quote, heading and list item has dedicated real-key regressions.

## Deliberate breaks

| Change in isolation | What failed |
|---|---|
| Remove scroll restoration | Four normal scroll tests caught text displacement, including 390, 783 and 1,440 px. |
| Bypass candidate verification | Four engine tests ran and recorded five issues. |
| Allow source edits to echo | Document text was duplicated. The targeted test recorded six issues. |
| Ignore an invalid deletion target | A forged insertion reached the document. The targeted test recorded two issues. |
| Remove incremental fallback | The independent full-parse comparison diverged on reference-link atoms. |
| Let a raw child supply editing CSS or a stale remembered caret | WebKit detected editable hostile content or a Backspace that deleted an unrelated paragraph character. |
| Add an extra DOM text node after each acknowledgement | Fresh-render comparisons detected it. Separately, a deliberately delayed DOM patch exceeded the latency target. |

The app’s hostile-document suite retains the no-defences control. Existing link tests exercise both the approved Cmd-click gesture and caret placement on a plain click. An empty document now has exactly one empty caret holder and zero text. Fixtures and golden outputs were preserved.


The final core suite exited 0 with `Test run with 98 tests in 9 suites passed` in both default and large-fuzz configurations. The large run took 6.779 seconds. A negative control appended an unverified character to the returned patch. The engine fuzzer failed at step zero on `attack.md` and reported the seed and exact UTF-16 offset. Five integrated native and real-WebKit conflict tests also exited 0 with `Test run with 5 tests in 3 suites passed`. A stale Backspace is refused if a concurrent change altered the grapheme it would remove.

The final `swift test --package-path App` exited 0 with `Test run with 128 tests in 9 suites passed after 76.044 seconds.` Both opt-in release timing tests were skipped.

The first integrated real-WebKit run caught a lossy line delete and a weak native marked-text assertion. The corrected IME test follows the actual DOM node, selection and commit events. Later runs exposed a phantom paragraph after redo, a stale selection that could overwrite a concurrent source edit, and a focus reset. A delayed-click control also reproduced a missing local Markdown link when a timer re-enabled editing before WebKit performed the link action. The fix holds the native link until after click handling. Ten immediate refocus-and-type cases exercised the path where the next native key arrives before DOM focus returns.

## Release measurements

At 60 keys/s the first run delivered 180 keys in order at every size. Key-to-DOM p95 was 10, 30, 46 and 285 ms at 4, 30, 100 and 850 KB. The run exited 1 with 2 tests and two issues. The delayed-patch control measured 163 ms.

At 850 KB, the initial core profile attributed about 0.70 ms p95 to the verified edit and 20.05 ms to comparing the complete HTML output. The host now uses the single changed block directly and acknowledges it in the same WebKit call. A separate reference-definition profile measured 378.30 ms p95 for full verification and 3.90 ms after adding bounded reuse of a standalone definition. These core-only figures exclude the DOM and paint.

### After removing the full-document HTML comparison

The first optimized run measured 23 ms p95 from `beforeinput` at 850 KB but 267.43 ms from native key dispatch. Its assertions only checked the page timer. I added an assertion for native dispatch so the test reports this delivery delay.

**Final release gate.** `MARKLIGHT_TIMING=1 swift test --package-path App -c release -Xswiftc -enable-testing --filter PreviewTimingTests` exited 1 with `Test run with 2 tests in 1 suite failed after 47.863 seconds with 1 issue.` Only the 850 KB native dispatch measurement exceeded its assertion. All 180 keys arrived in order at each size. Paint is excluded.

| Size | Page input → DOM p95 | Native dispatch → DOM p95 | JS patch p95 | Main thread late, max | Target |
|---|---:|---:|---:|---:|---|
| 4 KB | 6 ms | 6.13 ms | 2 ms | 4.60 ms | Measured |
| 30 KB | 6 ms | 5.37 ms | 1 ms | 4.43 ms | Measured |
| 100 KB | 7 ms | 7.40 ms | 2 ms | 4.66 ms | Under 20 ms, passed |
| 850 KB | 25 ms | 265.47 ms | 4 ms | 9.54 ms | Under 50 ms, failed |

The native measure begins when the harness sends the keyboard event to the window. The page measure begins at `beforeinput`. The delayed-patch control reached 134 ms p95. Implementation stopped at the performance gate. A further investigation should trace how long each native key waits before WebKit emits `beforeinput` in the large editable document.

| Size | Layout | First render | Source key median / p95 / max | Max main lateness | Updates / catch-up |
|---|---|---:|---:|---:|---:|
| 4 KB | Source | — | 1.5 / 2.7 / 4.6 ms | 24.3 ms | — |
| 4 KB | Split | 158.3 ms | 1.3 / 1.7 / 8.8 ms | 7.1 ms | 60 / 10.1 ms |
| 30 KB | Source | — | 1.6 / 2.2 / 6.9 ms | 10.2 ms | — |
| 30 KB | Split | 191.3 ms | 1.0 / 1.3 / 8.5 ms | 10.7 ms | 54 / 39.6 ms |
| 100 KB | Source | — | 1.7 / 2.3 / 9.2 ms | 11.6 ms | — |
| 100 KB | Split | 266.1 ms | 0.8 / 1.0 / 11.7 ms | 9.9 ms | 41 / 79.3 ms |
| 850 KB | Source | — | 3.1 / 3.5 / 6.5 ms | 4.6 ms | — |
| 850 KB | Split | 1,163.7 ms | 1.8 / 2.1 / 24.1 ms | 10.6 ms | 10 / 295.3 ms |

These source medians are close to M2’s. Some maxima exceeded the historical measurements, including a 24.1 ms source key in 850 KB split view versus 9.1 ms in M2. The broader no-regression condition is unconfirmed. No physical keyboard latency measurements were taken.

## Not verified by a person

`scripts/build-app.sh` exited 0 and ad-hoc signed the final app. The built app was opened and inspected in light and dark split views. A rendered key changed both panes, and Cmd-Z restored both in the light-mode bundle. Automated WebKit tests exercise actual native key events and the text input client. Real Pinyin and Japanese candidate choice, keyboard switching, partial-clause conversion, and sustained typing feel in the packaged M3 app still need the owner’s checks in `docs/m3-manual-ime.md`. M2’s owner decisions on raw HTML transport and preview scrolling remain open.
