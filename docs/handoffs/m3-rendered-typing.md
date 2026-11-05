# M3 rendered typing

| Handoff | Detail |
|---|---|
| Task | Verified rendered typing and deletion within one editable leaf |
| Branch | `agent/core/m3-rendered-typing`, based on merged M2 at `9957cd0` |
| Status | Done for everything automated. All performance targets pass on a visible page. Real IME and typing feel need the owner. |
| Contracts touched | None. The app uses the approved UTF-16 ranges and bridge messages. |
| Next step | Run `docs/m3-manual-ime.md`, and review "Found while building M3" in `docs/decisions.md`. |

## What changed

- The rendered editor keeps a snapshot of parsed top-level blocks. It reparses the edited block and its neighbours, checks that both outer guards still match, and shifts later offsets. Ambiguous boundaries, grammar changes, or unresolved reference context trigger full verification before commit. An idle check compares the same revision with a full parse. A mismatch logs the revision and rebuilds the page from the full result.
- Ordinary standalone reference definitions can supply context for a local parse. The fast path preserves definition order and conservatively bounds cmark’s expansion quota. Complex or unusually large definition sets still use the full path.
- The serializer changes one leaf’s atoms, checks the resulting structure, and returns one minimal source patch. Tests cover the exact edit position among repeated characters, literal Markdown punctuation, unchanged delimiter and entity spellings, and undo to original bytes. A deletion that would also discard unselected leading whitespace is refused.
- Swift verifies input on a serial worker and commits against the current buffer version. A local edit skips the source-typing delay. The renderer sends the changed block directly. The page queues navigation and further input until Swift acknowledges the DOM update. Verification rebases against intervening edits, refusing overlaps that would overwrite newly inserted text. Menu commands and WebKit history events both use the documented `undo` message so history stays ordered with outstanding typing.
- The page accepts text in paragraphs, headings, quotes and list items. Raw HTML, tables, code blocks, images and other protected content stay read-only. Plain clicks place the caret. Cmd-click uses the native routing policy. Unsupported operations beep. The source pane retains its selection and scroll, and a patch that cannot fit its storage resynchronizes from the buffer.
- IME edits preserve the original marked range. Swift receives a single edit on commit. Cancellation and full loads reconcile WebKit’s transient DOM. Undo/redo restores an actual pending paragraph so it can be typed into again.
- Top-level blocks sit in plain `div` wrappers of 64 under `#doc`, and `#doc` draws no focus ring. Together these fixed the 850 KB gate (see below). The wrappers belong to the page: Swift, the bridge, and block offsets are unchanged. A patched page matches a fresh render block for block, whichever wrapper holds each block, and a composition that damages the wrappers is repaired.
- A parsed document is now freed on the worker. Freeing it on the main thread made the first source key after each update take 29 to 30 ms at 850 KB.
- `TypingBench` measures rendered typing on a visible page, which `swift test` can't do. It's only part of the package when `MARKLIGHT_BENCH=1` is set.

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

The rows from the focus ring down were run on this round's page. The rows above them were run before it and weren't repeated.

| Change in isolation | What failed |
|---|---|
| Remove scroll restoration | Four normal scroll tests caught text displacement, including 390, 783 and 1,440 px. |
| Bypass candidate verification | Four engine tests ran and recorded five issues. |
| Allow source edits to echo | Document text was duplicated. The targeted test recorded six issues. |
| Ignore an invalid deletion target | A forged insertion reached the document. The targeted test recorded two issues. |
| Remove incremental fallback | The independent full-parse comparison diverged on reference-link atoms. |
| Let a raw child supply editing CSS or a stale remembered caret | WebKit detected editable hostile content or a Backspace that deleted an unrelated paragraph character. |
| Add an extra DOM text node after each acknowledgement | Fresh-render comparisons detected it. Separately, a deliberately delayed DOM patch exceeded the latency target. |
| Remove the focus ring rule | The focus ring test failed. |
| Put every block in one wrapper | The grouping test failed, and `TypingBench` exited 1 with 444 ms p95 at 850 KB. |
| Ignore wrappers in `toSource` | Selections between blocks mapped wrongly, with three issues. |
| Stop `blockOf` at direct children | 24 issues across the grouping and rendered typing suites. |
| Skip the repair after a composition, or its check for stray nodes | The damage test failed. The stray-node break got through at first, because the only scenario also removed wrappers. The test now applies each kind of damage on its own. |
| Leave emptied wrappers, skip spreading a large insertion, or lose the caret when spreading | The matching test failed each time. |
| Send insertions to the last wrapper | The large insertion test failed with two issues. |

The app’s hostile-document suite retains the no-defences control. Existing link tests exercise both the approved Cmd-click gesture and caret placement on a plain click. An empty document now has exactly one empty caret holder and zero text. Fixtures and golden outputs were preserved.


The final core suite exited 0 with `Test run with 98 tests in 9 suites passed`. The core package didn't change in the final round, and its earlier large-fuzz run also passed, in 6.779 seconds. A negative control appended an unverified character to the returned patch. The engine fuzzer failed at step zero on `attack.md` and reported the seed and exact UTF-16 offset. Five integrated native and real-WebKit conflict tests also exited 0 with `Test run with 5 tests in 3 suites passed`. A stale Backspace is refused if a concurrent change altered the grapheme it would remove.

The final `swift test --package-path App` exited 0 with `Test run with 135 tests in 10 suites passed after 100.198 seconds.` Both opt-in release timing tests were skipped. One existing test changed: `empty()` named the old nesting depth in a selector, and it asserts the same thing with the new depth. `dom()` and `countChanges` now list blocks across wrappers, and `dom()` also sees stray nodes, which it couldn't before.

Wrappers change nothing a reader can see. On a seeded 156 KB document mixing every fixture with headings, lists, tables, code, rules and raw HTML, all 17,761 element boxes matched the old page, as did the document height. The 29 fixtures alone would have proved little, as each fits in one wrapper.

The first integrated real-WebKit run caught a lossy line delete and a weak native marked-text assertion. The corrected IME test follows the actual DOM node, selection and commit events. Later runs exposed a phantom paragraph after redo, a stale selection that could overwrite a concurrent source edit, and a focus reset. A delayed-click control also reproduced a missing local Markdown link when a timer re-enabled editing before WebKit performed the link action. The fix holds the native link until after click handling. Ten immediate refocus-and-type cases exercised the path where the next native key arrives before DOM focus returns.

## Release measurements

All figures below come from the final code on 2026-11-05. The machine was about twice as slow that day as for the earlier tables, so those tables can't be compared with these. That's measured: see the M2 column below.

### What was wrong at 850 KB

The recorded 265 ms badly understated the problem. On a visible page the committed branch fell seven seconds behind in five seconds of typing.

`sample` on the WebContent process during a 900-key soak showed its main thread saturated. Keys arrived every 16.7 ms and took about 33 ms each, so WebKit's queue grew for as long as typing went on, reaching 18 seconds behind after 15 seconds. A p95 taken from a short burst was sampling a growing queue, which is why it swung between 265 and 2,800 ms between runs.

| Share of the main thread | Cause | Fix |
|---|---|---|
| 38% | Painting the focus ring on `#doc`. WebKit walks every box in the element to find the ring's edges, on every paint. It also drew a visible line across the page. | `#doc:focus { outline: none; }` |
| About 16% layout, 16% paint, 2% render tree | WebKit's loops over the 15,000 direct children of `#doc` | Wrappers of 64 |
| 12%, then 42% of what remains | On every keydown WebKit invalidates the focused element, then walks its whole subtree in `Element::resetComputedStyle` | None available. See "Known limits" |

The caret's position in the file made no difference, which ruled out WebKit measuring text from the start of the editing host.

| 850 KB on a visible page, 60 keys a second | Median | p95 | Worst |
|---|---:|---:|---:|
| As committed, 300 keys | 2,464 ms | 6,917 ms | 7,323 ms |
| Focus ring fixed, no wrappers, 180 keys | 268 ms | 444 ms | 458 ms |
| Final, 180 keys | 12.8 to 14.1 ms | 15.2 to 18.8 ms | 31.5 to 35.9 ms |

A separate 900-key run on an earlier build with wrappers measured 15.0 ms median, 20.0 ms p95 and 33.4 ms worst, with no key over 40 ms and no backlog.

### Gate: a visible page

`MARKLIGHT_BENCH=1 swift run --package-path App -c release -Xswiftc -enable-testing TypingBench` ran four times in a row. Each exited 0, none was discarded, and all 180 keys arrived at every size. The bench counts keys, and the hidden-page test below checks their order. The figures are native key dispatch to DOM, not counting paint.

| Size | Median | p95 | Worst | Target |
|---|---:|---:|---:|---|
| 4 KB | 1.3 to 2.3 ms | 2.8 to 3.9 ms | 18.1 to 20.7 ms | Measured |
| 30 KB | 2.1 to 2.7 ms | 3.4 to 4.0 ms | 9.2 to 14.3 ms | Measured |
| 100 KB | 1.8 to 2.6 ms | 3.2 to 4.1 ms | 10.8 to 16.7 ms | Under 20 ms, passed |
| 850 KB | 12.8 to 14.1 ms | 15.2 to 18.8 ms | 31.5 to 35.9 ms | Under 50 ms, passed |

`PreviewTimingTests` can't see this. `swift test` never runs AppKit's event loop, so WebKit treats the page as hidden: `visibilityState` is `hidden`, `requestAnimationFrame` never fires, and timers are throttled. The bench runs a real event loop, requires `visible`, floats on all Spaces, and throws a run away if visibility changes during typing, because that causes a one-off restyle (see "Known limits"). An earlier build failed one run in three with 216 ms p95. It had 144 frames where the others had about 190, and it wasn't traced. Of nine later traced runs, one lost frames the same way and showed `visibilitychange` firing mid-run, with two slow keys at that moment. The other eight had no slow keys.

### Hidden page

`MARKLIGHT_TIMING=1 swift test --package-path App -c release -Xswiftc -enable-testing --filter PreviewTimingTests` exited 0 with `Test run with 2 tests in 1 suite passed after 65.043 seconds.` All 180 keys arrived in order at each size, and the delayed-patch control reached 147 ms.

| Size | Page input to DOM p95 | Native dispatch to DOM p95 | JS patch p95 | Main thread late, max | Target |
|---|---:|---:|---:|---:|---|
| 4 KB | 10 ms | 9.92 ms | 2 ms | 13.07 ms | Measured |
| 30 KB | 8 ms | 7.36 ms | 2 ms | 4.61 ms | Measured |
| 100 KB | 8 ms | 8.55 ms | 2 ms | 4.64 ms | Under 20 ms, passed |
| 850 KB | 23 ms | 31.05 ms | 6 ms | 13.20 ms | Under 50 ms, passed |

The test now waits 3 seconds before typing, past a one-off restyle that otherwise lands in the burst. One earlier run measured 97 ms p95 at 30 KB with the test process's own main thread 125 ms late. It didn't repeat in the final run or in any bench run, and 30 KB has no target, so it was noise as far as I can tell, not a proven cause.

### Source pane, against M2 on the same day

M2 is `9957cd0`, exported, built and run the same day, once. Each cell shows M2, then the final code. Times are in ms.

| Size | Layout | First render | Key median | Key p95 | Key max | Main late, max | Updates | Catch-up |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 4 KB | Source | | 1.7 / 1.6 | 2.7 / 2.8 | 20.1 / 6.3 | 33.8 / 36.9 | | |
| 4 KB | Split | 404 / 294 | 1.3 / 1.3 | 1.8 / 2.1 | 7.2 / 6.1 | 8.6 / 13.9 | 60 / 60 | 15 / 15 |
| 30 KB | Source | | 1.8 / 1.7 | 3.2 / 2.9 | 7.3 / 8.9 | 14.7 / 12.9 | | |
| 30 KB | Split | 303 / 295 | 1.2 / 1.3 | 1.7 / 1.6 | 8.1 / 7.4 | 11.1 / 16.0 | 50 / 49 | 61 / 32 |
| 100 KB | Source | | 1.8 / 1.8 | 3.1 / 2.9 | 10.8 / 11.0 | 12.0 / 14.8 | | |
| 100 KB | Split | 479 / 583 | 1.3 / 1.4 | 1.6 / 1.7 | 9.6 / 9.2 | 18.0 / 20.6 | 30 / 30 | 147 / 161 |
| 850 KB | Source | | 3.3 / 3.3 | 3.7 / 3.8 | 6.3 / 6.1 | 6.2 / 4.8 | | |
| 850 KB | Split | 2,344 / 2,189 | 3.5 / 3.2 | 5.8 / 3.6 | 15.8 / 6.8 | 20.7 / 19.2 | 6 / 7 | 796 / 927 |

The differences in either direction are within what repeat runs of the final code showed: 100 KB split first render ranged from 502 to 690 ms across four runs, and 850 KB catch-up from 673 to 927 ms. Alternating the old and new page three times showed wrappers cost source typing nothing. With M2 run only once, this shows no regression, not that the two are identical. No automated assertion covers the source key maximum: the evidence for the fix is the same test before and after, 29 to 30 ms down to about 6 ms.

## Known limits

- **A one-off restyle.** A full style and layout pass ran once when the page's visibility or activation changed with the pane focused, about two seconds after a window opened, or when something hid the window. It took roughly 220 to 280 ms at 850 KB. It isn't a cost of typing, and a second burst of typing didn't trigger it again. The link to visibility comes from the traced run and the frame counts, not from a profile of that exact moment. Expect a short pause at this size after switching back to the window.
- **The remaining per-key walk.** `resetComputedStyle` takes about 6 ms a key at 850 KB and grows with the number of elements, so files much larger than this will fall behind sooner. At 850 KB and 60 keys a second, WebKit's main thread was 84% busy. It can't be removed from the page. The profile shows the invalidation inside `EventHandler::internalKeyEvent`, and the walk only ran while `#doc` held focus. Forcing a style flush at `keydown` didn't help, and the fix that would work, smaller editing hosts, would break selection across blocks.
- **The profile is of one WebKit.** These costs were measured on macOS 26.5.2. The fixes are plain CSS and DOM, but macOS 14 hasn't been measured.

## Not verified

- **Typing in the packaged app.** `scripts/build-app.sh` exited 0 and ad-hoc signed the final app. The bundle was launched and looked at in split view in light and dark, and it rendered correctly. No keys were sent to it on the final code, as nothing here can drive one. `TypingBench` uses the real document and window controller classes in a real event loop, with native key events sent through `sendEvent`, but it isn't the bundle. The earlier bundle check, where a rendered key changed both panes and Cmd-Z restored both, predates this round.
- **Real keyboards and input methods.** No physical keyboard latency was measured. Automated WebKit tests exercise native key events and the text input client. Real Pinyin and Japanese candidate choice, keyboard switching, partial-clause conversion, and sustained typing feel still need the owner's checks in `docs/m3-manual-ime.md`.
- **Open owner decisions.** M2's decisions on raw HTML transport and preview scrolling remain open.
