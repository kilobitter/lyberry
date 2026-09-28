# Accepted — Games platform filter, Lyberry 0.4.1+6

2026-09-25. Astra reviewed the actual changes against the captured 0.4.0 source
baseline (`work/baselines/platform-filter-pre-041`) and accepted the final
implementation after one consolidated correction cycle. Flash implemented,
debugged, tested and built the feature through the existing verified native
`astra_flash_builder` route; no model/provider switch or paid setup probe.

## Behavior and scope

- Games alone shows the full-width Platform dropdown, below the medium tabs.
- Options derive from all saved games, independent of search. Blank platforms
  are omitted; whitespace and case duplicates collapse; names sort alphabetically.
  No platform aliases are invented and stored metadata remains unchanged.
- Platform and text search combine. All platforms removes the platform predicate;
  leaving Games or clearing filters resets it. Games without platforms remain
  visible under All. With no named platforms, the dropdown is disabled.
- Reloads recompute options after library edits/imports. When the final matching
  game disappears, selection returns to All. Casing-only option changes retain
  the logical filter while resolving the selected value to the exact new label.
- Existing asynchronous load guards protect against stale results. Repository,
  database schema, credentials and provider behavior are unchanged.

## Review and evidence

The initial patch had a dropdown assertion risk when an active option's canonical
capitalization changed. Astra also identified a casing preference inconsistent
with its documentation. Both findings in `REVIEW-PLATFORM-FILTER.md` are resolved
in the inspected correction diff: exact refreshed option selection, exact UI
membership guard, and mixed-case preference preserving abbreviations. Regression
tests first reproduced the failures and then passed.

Worker final evidence in `evidence/platform-filter/final-verification.log`:
16 focused tests, 413 full-suite tests, analyzer clean, and 134 Dart files with
zero formatting changes. Astra inspected the closed and narrow large-text
renders; final correction did not change them. Historical evidence images match
the captured baseline byte-for-byte.

Corrected Android build succeeded, version 0.4.1/code 6. Astra independently
checked APK ZIP integrity, all three Flutter native architectures (arm64-v8a,
armeabi-v7a, x86_64), size and SHA-256:

`201059210 bytes`

`63dc4d555ed4abdad8e604929311e9053a10f272a4b4c19592e6c5f07a4ebe0a`

The APK was reinstalled on the Pixel 8a/API 37 emulator, launched, and exercised
for Games/All visibility with the existing one-copy library preserved. Populated
menus/filtering are covered by seeded widget/render tests; the emulator has no
saved games. iOS runtime testing remains unavailable in this environment.

## Integration

Accepted changes remain in the shared workspace. Deliverables are the 0.4.1 APK
and curated source ZIP, with checksums and a source manifest. Packaging excludes
device databases, keys, caches, build folders and transient golden failures.
Earlier versioned releases remain unchanged. No commit, push or deployment.
