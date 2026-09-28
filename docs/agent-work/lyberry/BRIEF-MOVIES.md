# MOVIES — UPCMDB lookup, Lyberry 0.5.0+7

## Objective and scope

The user requests a movie equivalent of the working ScanDex/IGDB games flow,
using https://upcmdb.com/. Implement UPCMDB barcode identification/metadata and
explicit movie-title search for DVD/Blu-ray, with the existing candidate choice,
editable copy and manual fallback. UPCMDB provides both identification and data;
no TMDB, OMDb, LLM or other new service is needed for this phase.

Astra owns architecture, contracts and acceptance. The existing native Flash
worker owns one end-to-end implementation, regression/debugging, tests, renders
and Android build/device verification bundle. The existing verified route is
reused. No new agents, delegated orchestration, paid setup probe or model switch.

Repository: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry`.
No Git repository; preserve all existing changes. Baseline:
`/Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/baselines/movies-pre-050`
(499 curated files plus BASELINE.json, from 0.4.1 current source). You are not
alone in the workspace; do not revert others' work. Root owns this brief,
CHECKPOINT, review/acceptance, and source packaging.

## Verified public contract (2026-09-25)

Primary sources: https://upcmdb.com/api, /faq, /pricing, /demo. These are rendered
SPA pages. Their public client script `/assets/index-CR6jLKBG.js` contains the
page's documentation text. Parent scratch `work/upcmdb-site.js` and
`work/upcmdb-api.html` are public evidence, not application dependencies. Read
only relevant snippets if needed; no private site state or credentials.

- **Actual documented API base:**
  `https://us-central1-upcmdb-cbae5.cloudfunctions.net/api`.
  The homepage's `https://upcmdb.com/api/v1/...` marketing example is not the
  detailed API reference base. Use the documented Cloud Functions base.
- Auth header: `x-api-key: YOUR_API_KEY` (no Bearer prefix, no URL key).
- GET `/v1/lookup/:upc` for UPC-12.
- GET `/v1/lookup/ean/:ean` for EAN-13.
- GET `/v1/search?title=...&year=...` for explicit title search; title required,
  optional four-digit year. Returns an array. No documented pagination needed.
- GET `/v1/lookup/imdb/:imdbId` also exists but is not needed here.
- API reference's example is a FLAT object with `upc`, `title`, numeric `year`,
  `format`, `special_features`, `publisher`, `imdbID`, `type`, `plot`, `runtime`,
  `genre`, `director`, `actors`, `imdbRating`, `rated`, `mediaType`.
  Website demo additionally displays `productImageUrl`. Homepage example uses
  `{status: 'success', data: {...}}`; support flat object/list and this explicit
  data object/list wrapper. Do not silently accept arbitrary response shapes.
  API sample UPC is `85391163114` (leading zero omitted); see matching policy.
- Documented errors: 401 missing/invalid key, 403 insufficient permission,
  404 not found, 429 quota exceeded. Do not surface raw service error text.
- Free tier: 500 requests/month for hobby/prototyping. Commercial use appears
  on paid plan; no purchase or account setup authorized. Note future publishing
  consideration in README without creating an app permission/approval flow.
- The public demo uses `/v1/demo/lookup/:code`, separate from authenticated API.
  Root bounded probes of `883929638482`, `5051888100639`, `5051891186415`,
  `5051888125168` received Cloudflare 403 browser-signature denial. Coverage is
  UNKNOWN, not 'no match'. No further demo retries, browser-signature changes,
  hidden credentials, account creation, or production authenticated smoke calls.
  Parent `work/upcmdb-public-probes/` contains the responses. Do NOT build the
  app on this demo endpoint. Synthetic fixtures are not live coverage.

## Architecture and failure contracts

1. Dedicated `lib/services/movies/` adapter/service implementing MetadataProvider
   plus a small injectable MovieCatalog interface for explicit title search and
   credential invalidation. Add ProviderRole.movies. AppServices/main wire one
   service, one key store and shared barcode/title rate state. Follow existing
   GameCatalog/controller/screen structure without refactoring working games.
   Existing bounded HttpTransport.get can be reused: always pass explicit timeout
   (15s), 1MiB cap, followRedirects:false. Construct URI only from the fixed
   HTTPS/443 documented host+base+allowed paths, validated identifiers and
   queryParameters; never accept a service-supplied endpoint. If a new transport
   wrapper is needed, keep it in movies with the same bounded policy. No global
   transport weakening, dependency changes or platform permission changes.

2. Routing: DVD/Blu-ray primary => movies, then existing general fallback.
   Null hint non-ISBN => movies alongside the existing games/music primary,
   then general fallback. Books/music/games explicit hints and all ISBN forms
   must never send a UPCMDB request. EAN-8 unsupported => clean empty result.
   Missing movie key => no request, clean empty provider result, existing
   fallback proceeds. Title-search UI exposes setup guidance when missing key.
   A stored but unreadable/invalid key is a typed failure, not no-match.

3. UPC-A, or EAN-13 with leading zero equivalent to UPC-A, use one UPC-12 call.
   Other non-ISBN EAN-13 uses EAN endpoint unchanged; never truncate European
   EANs. Avoid retrying equivalent forms and spending double quota. Preserve
   scanned/typed canonical barcode into editor on BOTH barcode and title paths.
   A response containing returned codes must match the requested equivalent
   code before claiming exact. Tolerate numeric/short UPC only by left-padding
   digits to 12, validating checksum and comparing; never infer arbitrary IDs.
   Reject explicitly mismatched-code barcode records. If title exists but code
   evidence is absent, possible-match labeling is permissible (never invent
   an exact code). Title results are ALWAYS possible matches and never replace
   the original scanned code with another edition's code.

4. Map title, director=>creator, validated year, publisher, plot=>description,
   productImageUrl=>cover. Optional runtime/genre/cast/edition details may be
   appended clearly to description. DVD maps dvd; Blu-ray/BD/4K/UHD maps bluray,
   retaining 4K/edition text so it is not lost. Unknown format uses supplied
   DVD/Blu-ray hint or stays editable/unspecified; do not invent a format.
   Source: validated IMDb `tt` ID URL when provided, otherwise UPCMDB public
   page (never credential URL). Covers public HTTPS, no userinfo/private hosts
   and no API credentials; use existing downloader safeguards. External ratings
   must NOT populate the user's personal rating, review or notes.
   Do not collapse different editions under the same IMDb ID: use supplied
   UPC/EAN identity + format, with deterministic safe fallback for missing ID.
   Bound parsed/title results to 20 valid unique candidates; ignore incomplete
   rows, reject wholly malformed/error shapes with a typed failure.

5. One conservatively spaced request/second across barcode/title paths, shared
   429 cooldown honoring bounded Retry-After; no hidden automatic retries.
   Clean results may use existing cache; failures must remain retryable.
   404/empty list => no match; 401/403 => key/access guidance, 429=>quota guidance;
   timeout/network/malformed/oversize each yields stable sanitized typed failure.
   Other provider results and manual/web/link actions remain usable.

6. Add MovieKeyProvider.upcmdb implementing CredentialKey, stable storage key
   `lyberry.movies.upcmdb_key`, unique slug `upcmdb`. Reuse SecureApiKeyStore
   validation/masked save/replace/remove behavior. Settings section Movie lookup
   key with signup and API-reference links, concise disclosure that barcode/title
   is sent to UPCMDB and keys stay local. No API call on key save/settings-open.
   No key in export, log, source, screenshot or backup. Capture service before
   awaits so invalidation runs after edits even if Settings route unmounted.
   Invalidate metadata cache and movie service generation on write/remove
   success OR error (storage might have changed before reporting an error).
   Check credential generation after async read/admission and just before HTTP,
   and again before accepting results/cache. Queued/inflight work using removed
   keys must not publish stale answers. Existing web/game key semantics preserved.

## UI contracts

- Add 'Search movies by title' to candidates/result/no-match/failure views for
  DVD/Blu-ray or unknown non-ISBN, parallel to existing game action eligibility.
  Never automatically search a guessed title or silently pick a result.
- Separate movie search screen with title and optional year input, submit,
  loading/empty/error/retry/manual paths, source/format/edition labels and
  candidate selection. No network until explicit submit; title trim+max200 chars,
  reject blank; optional year four digits (reasonable range), encoded query.
- Selection returns existing LookupChoice then editable draft/save flow.
  Scanned barcode, personal fields and local library remain unchanged until
  user explicitly saves. Unknown format stays an explicit editor decision.
- Existing dark Redline/Oxanium styling; loading/dispose/stale-search guards.
  Narrow 320px/1.6x text layouts and repeated failure keys must remain safe.
- Missing key gives Settings link and manual entry; return from Settings refreshes
  key state without an app restart. No dedicated movies home filter requested.

## Implementation ownership and sequence (one bundle)

Own new movie service/model/controller/screen/tests plus bounded integration in
domain/lookup.dart, services/metadata_service.dart, keys/api_key_store.dart,
app_services.dart, main.dart, candidates_screen.dart, settings_screen.dart,
test support/fakes, needed fixtures/current goldens, README, pubspec/version.
Do not change library/database/backup schemas or existing games/platform filter.
Internal sequence: service/auth/routing+tests; title/UI/settings+tests; full
verification/render/debug; Android release artifact/report. No interim handoffs.

Version 0.5.0+7. Prior deliverables untouched. Report:
`docs/agent-work/lyberry/REPORT-MOVIES.md`; evidence under `evidence/movies/`.
Preserve historical evidence images after full tests (helpers can rewrite them);
new renders belong in movies evidence, current golden baselines may update.

## Required verification and completion

- Unit/fixture tests for UPC/EAN paths/equivalents, actual documented flat and
  wrapped forms, list/title/year encoding, metadata/format/identity, malformed
  and no-match paths, shared quota/cooldown and deterministic credential races.
- Transport: fixed HTTPS host/path and no redirects, whole-request timeout,
  size limits, invalid key controls and sanitized errors. Use fake/local test
  seams only; never send dummy secrets to an external provider.
- Routing tests prove explicit non-movie/ISBN never reaches UPCMDB and primary
  movie hit avoids general fallback; missing key still uses existing providers.
- Widget tests for eligibility, setup, key save/remove invalidation, explicit
  search/choice preserving code, error/repeated failures, and small/large text.
- Flutter analyze, suppress-analytics Dart format check, focused then full suite
  once on final tree. Baseline 413 tests. Meaningful regressions, not duplicate
  assertions solely increasing count. Renders of key UI states for review.
- Build with existing Flutter/JBR21/fresh Gradle recipe and verify APK code7/name
  0.5.0, all three architectures, zip integrity/hash. Output
  deliverables/lyberry-0.5.0-debug.apk + checksum. No stale/partial build artifact.
- Emulator install-r/launch, key-missing/settings/movie action smoke and library
  preservation. No real keys/API quota use and no adding device records just to
  seed QA. If emulator unavailable, report exact evidence; never claim iOS tested.
- Report exact modified files, passed commands, artifact hash, screenshots,
  known limitations and live API coverage unverified. Stop ready_for_review.
  Astra reviews one actual diff plus evidence then packages curated source.

No git commit/push, deployment, account/subscription changes, paid requests,
ambient secret discovery, recursive delegation or permissions weakening.
