# Astra acceptance — Lyberry 0.4.0+5

Accepted 2026-09-25 for personal Android testing and portable Flutter source.
Astra owned architecture, contracts and review; the native astra_flash_builder
Flash child owned implementation/debugging/testing/build. Previously verified
gpt-6-astra root and deepseek/deepseek-v4.1-flash route evidence was reused;
no additional paid setup probe or route change was performed.

## Accepted behavior

ScanDex v2 barcode lookup provides game/platform IDs; IGDB enriches metadata.
Unknown games can be searched explicitly by title, with platform-specific
candidates, then reviewed/edited/saved using the existing copy flow. ScanDex
partials remain available when enrichment fails. Public-source mappings do not
prove a particular regional box/edition; user review remains necessary.

Credentials are entered in Settings and stored via the existing OS secure store.
No shared credential is bundled. Twitch token exchange uses a form body, fixed
HTTPS endpoints, no redirects and sanitized errors. Per-request spacing,
concurrency and429cooldown are shared across game lookup paths. Credential-change
checks prevent the specific stale request/cache/token cases in regression tests.
Existing personal fields, copy identity, backup schema and web lookup remain.

## Review and evidence

- Actual diff reviewed against398-file games-pre-040 baseline, including new
  files, then the correction diff against163-file games-review1 baseline.
- One consolidated review correction addressed setup return, documented schema,
  matching, transport/credential handling, cache and token races, throttling,
  storage failures, complete editor/save flow and evidence accuracy.
- A narrow additional correction was justified by concrete credential-use risk:
  queued IGDB work could send after removal; freshness is now checked after gate
  admission and storage reads, and cancellation no longer incurs quota cooldown.
- Reviewed before/after failing queued-send regression, final397-test full-suite
  log, analyzer (no issues), formatter (132files,0changes), build success and
  emulator evidence. These tests cover named cases, not all possible scheduling
  interleavings. No redundant root full-suite rerun.
- Reviewed game-result and Settings renders including small/large-text render
  evidence. Final Android install/launch preserved the one-copy emulator library;
  worker recorded no fatal/ANR. Own synthetic ScanDex key was removed afterward.
- Restored the historical p2 candidate image once during root integration because
  the golden harness re-exported it; retained the new image under evidence/games.
  Historical settings evidence and prior versioned deliverables are preserved.
- Root independently checked APK SHA256 and zip integrity (523entries).

Final APK: deliverables/lyberry-0.4.0-debug.apk,201039106bytes.
SHA256:4d10b6e38f918c3acae045b24381b2a7c34fa2a7475b0ca147b8b66e1c236565.
Portable source is packaged by parent work/package_lyberry_040.py with manifest
and checksum; excludes device databases, local SDK/build caches and secrets.

## Limits and next use

No real ScanDex/Twitch/IGDB credentials were supplied, so authenticated external
calls have not been verified live. The public ScanDex UI returned no result for
the user's045496367619UPC (see COVERAGE-GAMES.md); synthetic successful Wii
fixtures are parser/flow tests only. Configure the three Games lookup keys in
Settings and try scanning or title search. iOS runtime is unverified. Public
distribution should move shared developer credentials behind a server proxy;
none was deployed. No account creation, ScanDex suggestion submission, Git
commit, store publication or paid web lookup was performed.
