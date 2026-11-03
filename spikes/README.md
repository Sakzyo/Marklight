# Spikes

Throwaway prototypes that answer one risky question each before real app code is written. See section 4 of `docs/plan.md` and the prompts in `prompts/`.

- One folder per spike (for example `spike1-ranges/`), each its own self-contained package or project.
- Spike code is never imported by `Sources/` or `App/`, and never merged into them. Copy ideas, not files.
- Each spike ends with a `REPORT.md`: result, evidence, fallback taken, recommendation. Copy the outcome into the spike table in `docs/decisions.md`.
- Fixtures worth keeping get promoted to `Tests/Fixtures/` (append-only).
