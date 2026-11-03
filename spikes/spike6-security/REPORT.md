# Spike 6 report: preview security and local files

**Result: PASS.** Relative images inside the document's folder tree load. Traversal, symlink escapes, non-image files and remote images are blocked. Nothing from the document ran script in the recommended setup. Links never navigate the preview: external links are handed to the browser, and Markdown links are opened in Marklight.

Date: 2026-11-03. macOS 26.5.2, Swift 6.3.3, DOMPurify 3.4.17. Throwaway code. The two decisions the owner needs to make are listed under "Open questions".

## What was built

A command-line harness that hosts a real `WKWebView` in an invisible window and renders `fixtures/attack.md`. It renders the file to HTML with swift-markdown's `HTMLFormatter`, sends real mouse clicks to every link, and reports what got through. It runs the same file under five combinations of defences, so each layer is shown to hold on its own. The baseline with no defences proves the attacks actually work.

```bash
cd spikes/spike6-security && swift build && .build/debug/spike6-security
```

On each run it builds a temporary folder tree: `repo/docs/` (the document's folder, with images, an SVG with script, `notes.txt`, `other.md`, a symlink inside the tree and a symlink out of it), `repo/assets/shared.png`, and `secret/secret.png` outside the repo.

DOMPurify comes from the npm registry tarball (`dompurify-3.4.17.tgz`, released 2026-10-12), checked against the registry's sha512 integrity value. It's bundled in `Sources/spike6-security/Resources/` with its license.

## Design

| Layer | What it does |
|---|---|
| **Custom scheme** `marklight-preview://doc/` | The preview's only origin. `/` serves the preview page. Any other path is a file relative to the document's folder. The handler percent-decodes the path, rejects NUL, takes the `realpath` (which resolves symlinks and `..`), and serves the file only if it's inside the document folder's real path, is a regular file, and has an image extension (png, jpg, gif, webp, avif, svg, bmp, ico). Everything else gets a 403. This settles the scheme name left open in `CLAUDE.md`. |
| **CSP** (HTTP header on the page) | `default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src marklight-preview: data:; media-src marklight-preview:; font-src 'none'; connect-src 'none'; frame-src 'none'; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'`. Served images get their own CSP and `nosniff`. |
| **Page JavaScript off** | `WKWebpagePreferences.allowsContentJavaScript = false`. The page world runs no script at all. |
| **Isolated world** | All Marklight JS (DOMPurify, render, DOM patching) runs in a named `WKContentWorld` through `WKUserScript` and `callAsyncJavaScript`. That works with page JS off and with `script-src 'none'` (checked). The page world can't see `DOMPurify`, Marklight's functions, or `window.webkit` (checked: all `undefined`). |
| **DOMPurify** | Runs on the rendered HTML before it goes into the DOM. Default config plus `FORBID_TAGS` for style, form controls, frames, object, embed, base, meta and link, and `FORBID_ATTR` for action and formaction. |
| **Navigation policy** | Allows only the initial page load and same-document `#anchor` jumps; everything else is cancelled. A real user click (`.linkActivated`) on http, https or mailto goes to the default browser. A click on a `.md` link inside the tree opens it in Marklight. Anything else is dropped. Navigations that aren't user clicks (meta refresh, frames) are never routed anywhere. `createWebViewWith` always returns nil, so `target=_blank` gets the same routing. |
| **Bridge** | One handler, registered only in the isolated world. It accepts exactly `{type: "ready"}`; any other shape is dropped and logged. Spike 3 will add the edit messages to `docs/bridge.md`. |

## Results

Outcomes of the attack file under each combination of defences. **Bold** marks an attack that worked.

| Check | **Recommended:** DOMPurify + CSP + page JS off | CSP only | Page JS off only | DOMPurify only | No defences (baseline) |
|---|---|---|---|---|---|
| In-tree images (`images/ok.png`, `./images/sub/nested.png`, `link-in.png` symlink, `with%20space.png`, `evil.svg`) | all 5 load | all 5 load | all 5 load | all 5 load | all 5 load |
| `../assets/shared.png`, `../../secret/secret.png`, `../../../../…/etc/passwd`, `/etc/hosts` | blocked | blocked | blocked | blocked | blocked |
| `%2e%2e/%2e%2e/secret/secret.png`, `..%2f..%2fsecret%2fsecret.png` | blocked | blocked | blocked | blocked | blocked |
| `link-out.png` (symlink out of the tree) | blocked | blocked | blocked | blocked | blocked |
| `notes.txt` (in tree, not an image) | blocked | blocked | blocked | blocked | blocked |
| `file:///etc/hosts`, `marklight-preview://elsewhere/…` | removed | blocked | blocked | removed | blocked |
| `https://example.com/pixel.png` (remote) | blocked by CSP | blocked by CSP | not loaded* | not loaded* | not loaded* |
| `onerror` handler | no effect | no effect | no effect | no effect | **ran** (`pwned-onerror`) |
| `onmouseover` injected through the link-attribute breakout | no effect | no effect | no effect | no effect | **ran** (`pwned-attr`) |
| `<script>` in the document, `<svg><script>`, `onload`, `ontoggle`, mXSS payload | no effect | no effect | no effect | no effect | no effect† |
| SVG with script, loaded as `<img>` | no effect | no effect | no effect | no effect | no effect |
| Dangerous tags left in DOM | none | 12 | 10 | none | 12 |
| `on*` attributes left in DOM | none | 5 | none‡ | none | 5 |
| `javascript:` / `data:` links left | none | 3 | 1 | none | 3 |
| `<base href="https://evil.example/">` | removed | blocked by `base-uri` | **rewrote relative links to evil.example** | removed | **rewrote relative links to evil.example** |
| `<meta http-equiv=refresh>` | removed | navigation attempted, cancelled, not opened | navigation attempted, cancelled, not opened | removed | navigation attempted, cancelled, not opened |
| Iframes, object, embed | removed | blocked by CSP, except the `srcdoc` iframe, whose navigation was cancelled by the navigation policy | loads attempted, all cancelled | removed | loads attempted, all cancelled |
| Remote CSS in `style` attribute (tracking) | blocked by CSP | blocked by CSP | not checked | **would load** (no CSP) | not checked |
| Preview navigated away after clicking every link | no | no | no | no | no |
| External links handed to the browser | example.com page, `_blank` link, mailto | same | same + 3 links on evil.example (via `<base>`) | same as recommended | same as "page JS off" |
| `other.md` opened in Marklight | yes | yes | no (sent to evil.example) | yes | no |
| Page world can see `window.webkit` / `DOMPurify` / Marklight JS | no / no / no | no | no | no | no |

\* example.com has no such file, so in modes without a CSP the image fails whether or not it was requested. The CSP modes report an `img-src` violation, which proves the request was blocked before it went out.
† `innerHTML` never runs `<script>` elements, and the payloads that would run needed handlers, which the baseline shows with `onerror`.
‡ With page JS off, WebKit drops `<script>` elements and `on*` attributes when parsing `innerHTML`.

Every layer stops the script attacks on its own. They fail differently on the rest: CSP alone leaves the dangerous markup in the DOM, and page-JS-off alone lets `<base>` hijack links. Use all three.

### Path policy, called directly

| Reference in the Markdown | URL WebKit requests | Result |
|---|---|---|
| `images/ok.png` | `…/doc/images/ok.png` | served |
| `link-in.png` (symlink to `images/ok.png`) | `…/doc/link-in.png` | served (as the target) |
| `images/with%20space.png` | `…/doc/images/with%20space.png` | served |
| `../assets/shared.png` | `…/doc/assets/shared.png` | denied (the URL resolver drops `..` above the root; see below) |
| `../../../../../../../../etc/passwd` | `…/doc/etc/passwd` | denied |
| `%2e%2e/%2e%2e/secret/secret.png` | sent as is | denied: outside the document folder (after decoding and `realpath`) |
| `..%2f..%2fsecret%2fsecret.png` | sent as is | denied: outside the document folder |
| `link-out.png` (symlink to `../../secret/secret.png`) | `…/doc/link-out.png` | denied: outside the document folder |
| `notes.txt`, `other.md` | | denied: not an image type |
| `images` (a folder) | | denied: not a regular file |
| `images/ok.png%00.txt` | | denied: NUL in path |
| `marklight-preview://elsewhere/etc/hosts` | | denied: wrong host |

## Found along the way

- **swift-markdown's `HTMLFormatter` doesn't escape attributes.** The link `[x](<x" onmouseover="…" data-x=">)` comes out as `<a href="x" onmouseover="…" data-x="">`. In the baseline, the handler ran when the mouse passed over it. Marklight's own `HTMLRenderer` must escape every attribute value (`&`, `<`, `>`, `"`, `'`) and must not reuse `HTMLFormatter`. DOMPurify catches this, but the renderer shouldn't depend on that.
- **Images from `HTMLFormatter` have no `alt` text**, which hurts accessibility. Another reason to write our own renderer, which is already the plan.
- **`<base href>` is a real attack** without sanitizing or `base-uri`: it silently pointed every relative link, including `other.md`, at an attacker's site.
- **Relative URLs can't climb above the page's URL.** The page is at `/`, so `../assets/shared.png` resolves to `/assets/shared.png`, which means *the document folder's* `assets/`, not the parent folder's. That's harmless today (the policy confines everything to the document folder anyway), but it's wrong if the access root is ever wider than the document folder. Fix: serve the page at the document's own path relative to the access root (for example `marklight-preview://doc/docs/README.md` when the root is the repo), so `../` resolves exactly as it does on disk and on GitHub.

## Open questions for the owner

1. **Remote images: blocked by default?** The CSP blocks them now. That stops tracking pixels and keeps the preview offline, but README badges (shields.io, CI status) are remote images and very common, so they would show as broken. Options: keep them blocked with a per-window "Load remote images" button (like Mail); allow `https:` images by default; or a global setting. Recommendation: blocked by default, with a one-click "Load remote images" bar when a document has any.
2. **Access root: document folder only, or the git repository?** The policy implemented is the document's folder tree (the plan's default). Docs in `docs/` often point to `../assets/` or `../images/`, which this blocks. Option: when the document is inside a git work tree, use the repo root (the nearest folder containing `.git`) as the root, and serve the page at its matching path (see above). Recommendation: the repo root when there is one, otherwise the document folder.
3. **Style attributes are allowed** (`style-src 'unsafe-inline'`), because READMEs use `style` and `align` for layout. The worst case is visual spoofing inside the preview. Remote loads from CSS are still blocked by `img-src` and `font-src`. Keep it.

## Notes for later milestones

- Mermaid, KaTeX and highlight.js (M5–M6) should also run in the isolated world. KaTeX fonts will need `font-src marklight-preview:` with an `app` host or a separate path for bundled resources. Check that Mermaid works without `eval` (CSP doesn't cover isolated worlds, but page JS off might affect anything Mermaid inserts as `<script>`).
- The bridge surface is just `ready` today. Spike 3 adds the edit events; every message should be validated in Swift against an allowlist, as here.
- For the app: open external links with `NSWorkspace.shared.open`. Consider confirming before opening a URL whose visible text looks like a different URL.

## Not verified

- Behavior inside the real app target, with the sandbox off: should match, since nothing here depends on the CLI host.
- Clicks with modifier keys (Cmd-click, middle-click) and drag-and-drop of links or images out of the preview.
- Context-menu items ("Open Link", "Download Image", "Open Image in New Window"). These should be removed or routed in the app (`WKUIDelegate` menu customization) and need a check.
- Printing and "Export to PDF" (Should tier) with the same CSP.
- Audio and video elements (`media-src` allows the scheme, but the handler only serves image types today).
