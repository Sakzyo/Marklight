/// Block serializer for structural edits from the rendered pane.
///
/// Will re-serialize only an edited block and replace only its source range,
/// using per-file style detection (bullet marker, emphasis style, fences, list
/// numbering) and a semantic no-op check that keeps the original text when the
/// block's AST is unchanged. Never regenerates a whole file from an AST. See
/// `docs/plan.md` section 2.2.
