# Prompt: Spike 6, preview security and local files

Read `CLAUDE.md` and sections 2.6 and 4 (Spike 6) of `docs/plan.md`. Put this in `spikes/spike6-security/`.

**Question:** Can the preview load a document's relative images safely, with untrusted Markdown?

**Build:**

1. A `WKURLSchemeHandler` for a custom scheme (for example `mdfile://`) that serves files relative to the open document's folder.
2. A strict Content-Security-Policy for the preview page: scripts only from bundled resources, no inline scripts from the document, and image sources limited to the custom scheme and `data:`.
3. HTML sanitization of Markdown HTML blocks with DOMPurify.
4. Link handling that cancels in-page navigation and opens links in the default browser.

**Test files:** a Markdown file with relative images, `../../` traversal attempts, symlinks pointing outside the folder, a `<script>` tag, an `onerror` attribute, a `javascript:` link, an iframe, and a remote image.

**Pass criteria:**

- Relative images inside the document's folder tree load.
- Traversal and out-of-tree symlinks are blocked (policy: document folder tree only; report the policy you implemented).
- Scripts and event-handler attributes from the document never run.
- Links open in the browser, not inside the preview.
- The JS bridge exposes only the minimal message API.

**Deliverable:** `spikes/spike6-security/REPORT.md` with a table of attack cases and outcomes, the CSP used, and open questions (for example, whether remote images should be allowed by default). Timebox: 1 to 2 days.
