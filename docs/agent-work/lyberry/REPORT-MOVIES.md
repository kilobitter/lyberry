# REPORT-MOVIES — UPCMDB movie lookup (0.5.0+7)

- **STATUS:** **ready_for_review**. Corrections are implemented and fully
  validated by root: 80 focused tests, 485 full-suite tests, analyzer clean,
  format 0 changed, five movie renders plus the exact Settings golden updated
  and verified, historical images untouched, and the rebuilt
  `deliverables/lyberry-0.5.0-debug.apk` verified as 0.5.0/code 7 with all three
  ABIs and a matching checksum. Device smoke was unavailable (no online
  emulator); live UPCMDB coverage and iOS runtime are unverified.
- **Task ID:** MOVIES
- **Workspace:** `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry`
- **Brief:** `docs/agent-work/lyberry/BRIEF-MOVIES.md`
- **Review:** `docs/agent-work/lyberry/REVIEW-MOVIES.md`
- **Correction baseline:** `work/baselines/movies-review1`

Root runs Flutter/Gradle/adb because this worker's sandbox does not inherit the
granted Flutter/pub/Gradle cache permissions. Every command and its log path is
listed in §7; the sections above describe the code that those commands verify.

## 1. What was built

Dedicated UPCMDB movie adapter, service, title-search screen and Settings key
group, mirroring the reviewed games architecture without touching games.

| Area | File |
| --- | --- |
| Bounded transport, fixed endpoints, status mapping | `lib/services/movies/movies_transport.dart` |
| Documented response parsing, code matching, client | `lib/services/movies/upcmdb_client.dart` |
| `MovieCatalog` seam and search outcome | `lib/services/movies/movie_catalog.dart` |
| Shared spacing/concurrency/cooldown gate | `lib/services/movies/movies_request_gate.dart` |
| `MetadataProvider` + `MovieCatalog` implementation | `lib/services/movies/movies_lookup_service.dart` |
| Title-search state machine | `lib/state/movie_search_controller.dart` |
| Title/year search screen | `lib/ui/screens/movie_search_screen.dart` |

Integration (bounded edits only): `lib/domain/lookup.dart` (`ProviderRole.movies`,
`MetadataCandidate.format`, `MetadataCandidate.edition`),
`lib/services/metadata_service.dart` (movie routing + ISBN guard),
`lib/services/keys/api_key_store.dart` (`MovieKeyProvider.upcmdb`,
`lyberry.movies.upcmdb_key`), `lib/app_services.dart`, `lib/main.dart`
(one limiter/gate, one transport, one cache),
`lib/ui/screens/candidates_screen.dart` (movie action),
`lib/ui/screens/settings_screen.dart` (movie keys section, version label),
`pubspec.yaml` (`0.5.0+7`), `README.md`.

Tests: `test/services/movies/upcmdb_client_test.dart` (19),
`test/services/movies/movies_transport_test.dart` (10),
`test/services/movies/movies_lookup_service_test.dart` (20),
`test/ui/movie_lookup_flow_test.dart` (13), `test/golden/movies_render_test.dart`
(5 renders), `test/support/fake_movies.dart`, plus movie routing cases in
`test/services/routing_and_limits_test.dart` (7 of its 18 tests).

## 2. Behaviour

- **Routing.** DVD/Blu-ray hints ask the movie catalogue first and only run the
  existing general/book/music fallback when it produced nothing; an unknown
  non-ISBN code asks games/music/movies before the fallback; book, CD, vinyl and
  game hints and every ISBN form never reach UPCMDB. EAN-8 is a clean empty
  result with no request.
- **Codes.** UPC-A, and an EAN-13 that is the leading-zero form of a UPC-A, use
  one `GET /api/v1/lookup/:upc` call; other EAN-13 codes use
  `GET /api/v1/lookup/ean/:ean` unchanged. The identifier normalizer already
  guarantees a checksum-valid request; a returned record counts as exact only
  when it carries the requested code or its documented equivalent
  (leading-zero EAN-13, or a short numeric UPC that left-pads to the same
  checksum-valid 12 digits). Records with no code evidence are possible matches;
  explicitly mismatched records are a sanitized failure, never a wrong match.
- **Responses.** The documented flat record and the `{status, data}` envelope
  (object or list) are accepted; an error envelope, an unreadable body, a
  non-object shape or a wholly unreadable row list become typed malformed
  failures. Incomplete rows are ignored and results are bounded to 20 unique
  candidates.
- **Mapping.** title; director to creator; validated year; publisher;
  `plot` to description with clearly labelled optional runtime, genre, cast,
  edition, rating and rating-source details; `productImageUrl` to cover only
  when the existing cover policy accepts the URL. DVD maps to DVD,
  Blu-ray/BD/4K/UHD maps to Blu-ray with the edition text kept in
  `MetadataCandidate.format`/`.edition` and in the description; an unknown
  format keeps the supplied hint or stays unspecified. An external IMDb rating
  is description text only — the personal rating, review and notes stay empty,
  and a movie draft carries no stray platform value.
- **Identity.** `upcmdb:<code|imdb|title+year>|edition:<edition/publisher>||<format>`
  so different supplied UPC/EAN editions and different same-IMDb editions stay
  separate while identical rows deduplicate. Title results are always possible
  matches and never replace the scanned code in the editor.
- **Credentials and cache.** `MovieKeyProvider.upcmdb` reuses the secure store's
  validation, masked save/replace/remove and keystore-only storage; saving or
  removing a key drops cached lookups and bumps a credential generation. The
  generation is checked after the key read, inside the gate immediately before
  the request, and again before results are published or cached.
- **Failure classes.** 401/403 are key/access guidance, 429 is a quota failure
  whose bounded `Retry-After` (max 30 min) parks the shared gate, 5xx is
  unavailable, and timeouts/network/malformed/oversize stay sanitized. The same
  one-request-per-second spacing and 429 cooldown apply to the barcode and title
  paths, with no hidden retries.

## 3. Corrections in this pass (REVIEW-MOVIES.md)

1. **API prefix (P1).** Endpoint templates are now `/api/v1/lookup/:upc`,
   `/api/v1/lookup/ean/:ean` and `/api/v1/search` on the documented Cloud
   Functions host; the client test asserts the three complete production URIs,
   and the `matches()` rejections use the `/api` paths.
2. **Queued credential race (P1).** `MoviesLookupService` now re-checks the
   credential generation inside the admitted gate action, immediately before the
   client call, on both the barcode and title paths, keeping the post-response
   guard. New regressions: a barcode request queued behind a taken slot with
   `maxConcurrent: 1`, a barcode request waiting on the spacing rule, and a
   **title search** queued behind the taken slot using an explicit `Completer`
   boundary inside the transport instead of wall-clock timing. Each removes the
   key mid-wait, asserts the exact `unavailable` outcome and that the transport
   saw only the already-sent request, so both changed closures are covered.
3. **Strict codes (P2).** `codesAreEquivalent` now trims, then requires digits
   only; prefixed/suffixed/punctuated text never matches. The UPC canonical form
   still allows an 8–12 digit short numeric UPC left-padded to 12 with a valid
   checksum, plus the UPC-12/leading-zero-EAN-13 pair. Tests cover tolerated
   surrounding whitespace, rejected prefixed/suffixed/punctuated codes, the
   documented short UPC and a true European EAN-13. Both sides of every
   comparison are validated, so a direct `codesAreEquivalent` regression also
   proves that textually identical but unusable codes — wrong UPC/EAN check
   digits, a 14-digit value, a 7-digit value and a far-too-long value — are
   never a match.
4. **Cover policy (P2).** `_coverUrl` keeps a URL only when
   `CoverDownloader.isAllowedUri` accepts it (HTTPS, 443, no userinfo, no
   literal/private host, allowlisted cover host); the global allowlist was not
   broadened. Tests assert one accepted allowlisted cover and six rejected forms
   (http, userinfo, loopback, untrusted host, non-443, unparsable).
5. **Missing key (P2).** A missing key is now a clean empty provider result for
   every hint, so the general fallback answers normally and no spurious UPCMDB
   failure is reported; setup guidance stays in the explicit title search
   screen. Service and routing tests cover all hints plus the fallback outcome.
6. **Edition identity and display (P2).** Identity appends supplied edition and
   publisher (and title/year when no id exists), the new
   `MetadataCandidate.edition` carries the label, and movie result cards show
   `format | edition | year | creator`. Tests cover two same-IMDb/same-format
   editions with no codes staying separate, an identical duplicate collapsing,
   and the scanned code reaching the editor draft.
7. **Stale title controller (P2).** Editing the title or year now bumps the
   request token (so a late success *or* error cannot publish), `submit()` is a
   no-op while a request is running, and the completion check keeps comparing
   against the `_searchedTitle`/`_searchedYear` values captured when the request
   was submitted (that comparison itself was not changed in this pass). Tests
   cover stale success, stale error and duplicate submit. Game search was not
   touched.
8. **Copy (P2).** Settings now says only that UPCMDB is a third-party service
   used with the user's own key and that a request is sent only when asked; the
   accurate free-tier/commercial-use publishing consideration moved to README.
   The misleading "slower than the provider's own limit" comment in `main.dart`
   is now stated as a local policy. The Settings goldens are expected to change
   because of the new section and the `Lyberry 0.5.0` version row.

## 4. Verification results (root-run)

| Evidence | Result |
| --- | --- |
| `evidence/movies/correction-focused.log` | **80 passed** — 19 client, 10 transport, 20 service, 13 UI/controller, 18 routing |
| `evidence/movies/correction-analyze.log` | `No issues found!` |
| `evidence/movies/correction-format-check.log` | `Formatted 147 files (0 changed)` |
| `evidence/movies/correction-full-suite.log` | **485 passed** — the 413-test 0.4.1 baseline plus 67 movie tests and 5 routing tests |
| `evidence/movies/historical-images.txt` | 90 historical evidence images checked, 0 restored or overwritten |
| goldens | the five movie renders and the exact `games credentials settings at 390x844` Settings render were updated and then verified by the full suite |
| `evidence/movies/correction-android-build.log` | fresh Gradle rebuild: `BUILD SUCCESSFUL in 20s` |
| `evidence/movies/apk-badging.txt` | `versionName 0.5.0`, `versionCode 7` |
| `evidence/movies/apk-verification.txt` | ZIP integrity passed; `arm64-v8a`, `armeabi-v7a` and `x86_64` native libraries present |
| `deliverables/lyberry-0.5.0-debug.apk` | 176 255 296 bytes, SHA-256 `52f986e09d8c760550a1ed723873b3b5e407fa802161dc993daa7d8002bdd01f` |
| `evidence/movies/device-smoke.txt` | device smoke unavailable: only `emulator-5562`, offline |
| `root-focused.log`, `root-analyze.log`, `root-*-initial.log` | earlier pre-correction runs, including the telemetry-write aborts, kept for context |
| first correction focused run | 77 passed, 1 failed on a stale `/v1/…` path expectation; fixed in this pass (the `/api/v1/…` path assertion) |

**Build metadata issue (found by root's `aapt2` check, since corrected).** The
first Gradle build succeeded in 22s but produced a 0.4.1 artifact:
`android/app/build.gradle.kts` reads `flutter.versionName` /
`flutter.versionCode`, and the generated `android/local.properties` still
carried `0.4.1` / `6`, because a direct Gradle build does not re-sync those two
values from `pubspec.yaml`. No APK was copied from that build. Both generated
properties were then set to `0.5.0` / `7` (no source, pubspec or architecture
change) and the fresh rebuild in the table above produced the verified 0.5.0
artifact. (`ios/Flutter/Generated.xcconfig` is likewise stale at `0.1.0` / `1`;
it is an iOS-only generated file, out of scope for this Android artifact, and
iOS runtime remains unverified.)

## 5. Renders

`test/golden/movies_render_test.dart` renders
`movies_title_search_390x844.png`, `movies_title_search_results_390x844.png`
(two synthetic editions of one film, distinguished by their format labels),
`movies_title_search_320x568_scale1.6.png`, `movies_missing_key_390x844.png` and
`settings_movies_keys_390x844.png`. The 320x568 golden did not exist before this
pass, so the update run creates it; the corrected test scrolls to the exact
second-candidate key instead of the previous `find.text('Use this').first`.
The copies for review live in `docs/agent-work/lyberry/evidence/movies/`.
Historical evidence images in the other `evidence/*` directories were checked
(90 files) and none were restored or overwritten; the current golden baselines
are root's updated ones and are preserved as they are
(`correction-movie-goldens.log`, `correction-settings-golden.log`).

## 6. Known limitations and risks

- **No live UPCMDB coverage.** The public demo route answered with a Cloudflare
  browser-signature denial for the sample codes; no authenticated request and no
  real key was used. All provider behaviour is fixture-validated, so a
  documented-shape drift in the live service is possible and would surface as a
  typed malformed failure rather than a wrong match.
- Covers are kept only for hosts the existing cover policy already allows, and
  which hosts UPCMDB actually returns images from is unverified; the editor may
  therefore show no cover for a real poster URL.
- **Device smoke is unavailable:** only `emulator-5562` was present and offline,
  so the 0.5.0 install/launch, foreground and library-preservation checks were
  not performed. Camera capture, gallery picking, native file dialogs and iOS
  runtime behaviour remain unverified (`xcrun simctl` is not installed).

## 7. Command log

Flutter test/analyze and Gradle commands were run by root because the child
sandbox lacks toolchain-cache writes. Flash also ran static analysis and
formatting through the Dart SDK binary. Root-run evidence is recorded under
`docs/agent-work/lyberry/evidence/movies/`:

| Step | Log |
| --- | --- |
| Focused movie service/transport/UI + routing tests | `correction-focused.log` (80 passed) |
| Analyzer | `correction-analyze.log` (no issues) |
| Format check | `correction-format-check.log` (147 files, 0 changed) |
| Full suite | `correction-full-suite.log` (485 passed) |
| Golden updates and verification | see §5; `historical-images.txt` (90 checked, 0 restored) |
| Fresh Gradle build | `correction-android-build.log` (`BUILD SUCCESSFUL in 20s`) |
| APK metadata and integrity | `apk-badging.txt`, `apk-verification.txt` |
| Device smoke | `device-smoke.txt` (no online emulator) |

No commands remain.

## 8. Handoff

The phase is complete and handed back as **ready_for_review**: root owns
ACCEPTANCE/CHECKPOINT and the curated source package. Remaining unverified areas
are listed in §6 (no live UPCMDB call, no device smoke, no iOS runtime).
