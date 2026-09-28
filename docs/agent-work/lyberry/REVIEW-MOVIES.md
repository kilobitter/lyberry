# MOVIES — Astra review, changes requested

2026-09-26. Reviewed the actual implementation against movies-pre-050 and the
approved brief. Correction baseline: parent work/baselines/movies-review1.
Root executed Flash's validation commands because the child's existing sandbox
does not inherit the granted Flutter/Gradle cache permissions. 52 focused tests
and five movie renders passed; analyzer is clean. Full suite: 474 passed, one
expected Settings golden mismatch. No APK has yet been built for acceptance.

## Consolidated corrections

1. **P1 — Wrong production API path.** movies_transport.dart endpoint templates
   omit `/api`, the final component of the documented base. Actual URIs must be
   `https://us-central1-upcmdb-cbae5.cloudfunctions.net/api/v1/...` for UPC, EAN
   and title. Fix the allowlist and fixtures and assert complete production URIs.

2. **P1 — Queued requests can use removed credentials.** movies_lookup_service.dart
   checks generation before waiting on MoviesRequestGate, then only after HTTP.
   Both barcode and title paths must check generation inside the admitted action,
   immediately before the client call, after every gate/limiter await. Preserve
   the post-response guard. Add deterministic queued and spacing-wait regressions
   demonstrating no old-key HTTP after invalidation. Existing in-flight work may
   finish, but must not publish results. This concrete credential race warrants
   root's additional targeted security review.

3. **P2 — Non-numeric response codes can be called exact.** upcmdb_client.dart
   `_digitsOf` strips arbitrary letters, and equality bypasses checksum validation.
   Use strict trimmed numeric codes and validate checksum/length, while preserving
   the documented short numeric UPC padding and UPC/zero-EAN equivalence. Reject
   prefixed/suffixed text and malformed codes; test these plus valid true EAN-13.

4. **P2 — Unsafe/unusable cover URLs retained.** `_coverUrl` returns any supplied
   string. Reuse CoverDownloader.isAllowedUri to retain only permitted HTTPS cover
   URLs; do not broaden the global allowlist. Test accepted cover and rejected
   HTTP/userinfo/private/untrusted URLs. Downloader already blocks those requests;
   the adapter must also avoid retaining them as candidate metadata.

5. **P2 — Optional missing key creates a failure for movie hints.** Brief requires
   clean empty barcode provider results without a key for all hints, allowing
   general fallback normally. Keep setup guidance in explicit title search.
   Add fallback integration coverage with no spurious UPCMDB failure.

6. **P2 — Missing-code editions collapse and cannot be distinguished.** `_identity`
   falls back to IMDb+format, so different special_features/publishers for the same
   film/format collapse. Include stable supplied edition attributes in fallback
   identity and expose distinguishing edition text in title result cards. Retain
   separate supplied UPC/EAN editions and deduplicate identical records. Test two
   same-IMDb/same-format editions without codes and preserve original scan in editor.

7. **P2 — Stale title exceptions / duplicate submission.** MovieSearchController
   setters clear answers without invalidating request token; a late thrown error
   can publish under edited fields. Invalidate on edits and guard submit while
   already running. Capture request-local query state. Add stale success/error and
   duplicate-submit tests. Do not change game search.

8. **Product copy / final verification.** Settings currently calls UPCMDB a paid
   service despite the free tier and implies a server proxy substitutes for a
   commercial licence. Keep concise key/data-disclosure copy in app; put accurate
   publishing consideration in README. Remove unsupported provider rate-limit
   comparison in main.dart (our one-second spacing is a local policy). Update
   expected Settings golden (games_render_test.dart, exact test 'games credentials
   settings at 390x844') and affected new movie renders. Preserve historical
   evidence images independently of current golden baselines.

## Remaining acceptance work

Flash owns code, regression fixes and report/README. Root runs supplied commands
with `flutter --suppress-analytics <command> --no-pub ...` and Dart suppression;
no more child cache permission prompts/probes. Run final relevant tests, format,
analyze, full suite, then fresh Gradle build and available emulator smoke. Root
reviews corrections and final evidence, accepts and packages source. Authenticated
UPCMDB coverage and iOS runtime remain unverified; use no ambient credentials.

## Final resolution

All findings above are resolved and accepted. A narrow validation/debugging
follow-up closed the invalid-code equality shortcut, added the title credential
race regression and fixed one stale test assertion. Final evidence: 80 focused
and 485 full-suite tests pass, analysis/format clean, versioned APK verified.
See ACCEPTANCE-MOVIES.md for artifact details and verification limits.
