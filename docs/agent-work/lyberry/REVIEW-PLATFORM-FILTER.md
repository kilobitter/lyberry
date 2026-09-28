# Platform filter — consolidated Astra review

2026-09-25. Initial implementation reviewed against
`work/baselines/platform-filter-pre-041`; 410-test, analyzer, formatting, build
and emulator evidence inspected. Closed and narrow large-text renders reviewed.
Scope and appearance match the brief, but acceptance is pending one correction.

1. **P1 — selected value must exactly match the refreshed option.**
   In `LibraryController._reload`, `_hasPlatform` checks case-insensitively but
   retains the old selected spelling. If `PlayStation 4` is selected and the
   entry carrying that spelling is deleted or edited, a remaining
   `playstation 4` entry keeps the logical platform alive. The option changes
   spelling but the selected value does not. Home's `_hasOption` likewise
   returns true and passes that obsolete string into `DropdownButton`, whose
   equality check is exact, causing its missing-value assertion. Resolve the
   captured selection to the exact string in the freshly computed options
   before publishing the state; retain the logical filter across casing-only
   changes. Use an exact-membership UI guard (or reuse the resolved option).
   Add a widget regression for an active selection followed by editing/deleting
   its canonical spelling while an equivalent spelling remains; assert no
   exception, a valid exact dropdown value and continued correct results.

2. **P2 — capitalization preference contradicts its contract.**
   `_caseScore` counts uppercase ASCII letters, so shouted `PLAYSTATION 4`
   always beats `PlayStation 4`, contrary to its comment. Prefer mixed case
   when present, with deterministic readable fallback for all-upper/all-lower
   names (preserve legitimate abbreviations; never rewrite stored values).
   Extend deduplication coverage to mixed/upper/lower entries.

Keep the same bounded scope and 0.4.1+6 version. Run the regression first to
demonstrate the failure, apply both fixes, rerun appropriate focused tests,
analyzer/format and the full suite once on the final tree. Rebuild the APK,
verify/install the updated artifact preserving emulator data, and update the
report/README/checksums and final evidence. Preserve historical evidence and
prior releases. Astra retains acceptance/checkpoint/source packaging ownership.
