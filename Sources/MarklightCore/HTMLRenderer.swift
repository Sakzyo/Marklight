/// HTML renderer for the rendered pane.
///
/// Will walk the AST and emit HTML with `data-src="start:end"` on every
/// element, in the agreed range unit. Output is untrusted and sanitized in the
/// preview. See `docs/plan.md` sections 2.3 and 2.6.
