# Games lookup — Astra contract (2026-09-25)

## Objective and authorized scope
Build Lyberry 0.4.0+5: ScanDex resolves a scanned game barcode to IGDB game and
platform IDs; IGDB supplies metadata. When identification fails, allow explicit
IGDB title search and game/platform choice, then the existing editable/save flow.
Keep the library local, preserve existing data, and retain other providers and
web/manual fallbacks. The user approved this integration and own credentials in
Settings for personal testing. A public-distribution backend is future work.

Astra owns this contract and final review. One native astra_flash_builder owns
discovery, implementation, debugging, tests, routine visual/device QA and build.
Existing routing evidence in CHECKPOINT.md is reused; no live setup probe.

## Baseline and ownership
Repository: /Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry
No Git. Baseline: ../../work/baselines/games-pre-040 (397+ curated files with
BASELINE.json; absolute parent work/ under new-chat). Preserve prior deliverables
and unrelated work. You are not alone in the workspace; do not revert others.

Worker owns lib/, relevant test/ and test goldens, README.md, pubspec version,
necessary native configuration only if demonstrably needed, and a unique
REPORT-GAMES.md plus evidence/games/ under this docs directory. No DB/backup
schema migration is required. Do not edit BRIEF-GAMES.md, ACCEPTANCE-GAMES.md or
CHECKPOINT.md. No new dependency expected: existing HTTP, secure storage, URL
launcher and test seams suffice. If one is required, explain rather than rewrite
unrelated infrastructure. Do not auto-commit, deploy, publish, create accounts,
submit ScanDex suggestions, read ambient credentials, or delegate.

## Dependency-ordered single phase
1. Add bounded clients/credentials and games-provider contracts with tests.
2. Integrate provider routing, Settings and title-search selection/editor flow.
3. Verify security/error states, regression suite, visual QA, Android build and
   emulator smoke; report evidence for one batched Astra review.

## Stable architecture and behavior
- Extend MetadataProvider/ProviderRole with a games role. ScanDex+IGDB implements
  ordinary barcode lookup; a separate injectable GameCatalog/search interface
  exposes `Future<List<MetadataCandidate>> search(String title)` (or equivalent
  typed outcome with warnings) and credential/token invalidation. Return existing
  MetadataCandidate objects; library persistence still happens only in editor.
  Keep provider/client boundaries replaceable by a future server-side proxy.
- Game hint: games primary, existing general fallback only when empty/failed.
  Unknown non-ISBN: configured games alongside music before general fallback.
  Book/music/movie hints and ISBN auto-routing must not call games providers.
  Missing ScanDex credentials must send no request; for explicit game hint show
  actionable setup help while general fallback remains usable. Unconfigured
  games should not pollute unrelated automatic lookups with error warnings.
- ScanDex v2 GET https://scandex.gamery.app/api/v2/lookup?value=<normalized-code>,
  raw Authorization token header (NOT Bearer). Keep codes as strings, preserving
  UPC leading zeros. Existing normalization includes equivalent UPC/EAN. A 404
  or status=unmatched / igdb_metadata=null is no match, not a parser crash.
  Current result: {id,source,igdb_metadata:{id,name,platform:{id,name}}}.
  Validate IDs as positive integers. `source:user` is community supplied: label
  possible match; imported mapping may be exact code match, never edition proof.
- IGDB POST https://api.igdb.com/v4/games with Client-ID and Bearer app token,
  plain APICalypse query body. Fetch by exact numeric game ID with explicit
  fields: name,url,summary,cover.image_id,platforms.id/name,
  involved_companies.company.name/developer/publisher, release_dates.platform/y/date.
  Map developer->creator, publisher, summary, platform and platform-specific year.
  Do not choose a different platform's initial release year. Missing optional
  values remain blank. Requesting first_release_date for non-platform records is
  optional, but do not misrepresent it as a chosen-platform release year.
  Build cover HTTPS URL only from a validated image_id on images.igdb.com using
  documented image sizing. Keep personal rating/review/notes/photos untouched.
- Preserve ScanDex platform selection. A returned IGDB ID/platform mismatch must
  not silently become a different console or exact match. Safe partial ScanDex
  title/platform candidate with an enrichment warning is useful when IGDB is
  unavailable/unconfigured; preserve this fallback if trustworthy fields exist.
  Candidate identity must include game+platform to avoid merging console variants.
- Add 'Search games by title' to candidate empty/failed states for game/unknown
  medium, also accessible when unwanted matches are present. Explicit submit
  only, bounded input/results (20 games is adequate), no request per keystroke.
  Escape APICalypse quoted strings correctly; reject/control input length and
  controls. Search results are possible matches, show platform clearly and let
  the user choose the console when multiple exist. Can represent game/platform
  pairs as candidates, cap display work, deduplicate. Carry original scanned
  identifier through selection into existing editor and existing save/cover path.
  User can return/back/retry/manual without loss. Do not contact ScanDex /create.
- Respect lookup cache: credential save/replacement/removal clears relevant
  cached empty/full results and in-memory auth. In-flight old-credential work
  must not repopulate accepted cache/token after invalidation. New lookup can
  use new credentials immediately without restarting. Async search screens ignore
  stale completions on back/dispose/new query; no widget key collisions.

## Credentials and transport decisions (Astra)
- Add separate Games lookup Settings group: ScanDex API token, Twitch client ID,
  Twitch client secret. Reuse verified OS secure storage pattern; extending the
  existing key enum is allowed while retaining current persisted names. Keep web
  and game credential groups explicit so enum extension cannot show wrong fields.
  Mask values, no prefill of stored secrets, disable autocorrect/suggestions,
  support save/replace/remove with readback and actionable storage failures.
- This build accepts the user's own developer credentials for personal testing.
  Never embed shared app credentials. README must explain this is a development
  setup; public release should move shared credentials/token exchange server-side.
  Add practical official setup links/instructions in Settings/README. No account
  creation/authentication ceremony is needed during implementation.
- Twitch POST https://id.twitch.tv/oauth2/token using application/x-www-form-urlencoded
  BODY client_id,client_secret,grant_type=client_credentials. Do not put secret
  in query string. Cache token in memory only with expiry skew; deduplicate token
  acquisition; refresh once on IGDB 401, no retry loops. Validate response types.
  Clear credentials/token-associated state on replacement/removal, including
  races with in-flight exchange. No token/secret in logs, URLs, exceptions,
  screenshots, database, exports, source archives or persisted metadata.
- Use an injectable games-specific transport or carefully compatible extension;
  do not weaken existing web transport/page fetch protections. Fixed host AND
  endpoint/method allowlist (ScanDex lookup, Twitch token, IGDB games), HTTPS443,
  reject userInfo, redirects disabled, ordinary TLS verification, bounded overall
  deadline/body bytes, sanitized errors. Never forward credentials to redirects.
  Provider-response text must not be reflected into errors (may echo secrets).
- Share IGDB limiter across barcode and title calls, <=4 requests/second and
  bounded concurrency (<8), honor 429/cooldown. Prefer simple serialized requests
  spaced >=300ms. Token requests also bounded. Distinguish no match, invalid key,
  quota, malformed data, timeout/offline; preserve general/manual paths.
- Settings privacy copy must reflect title search sends typed title and game ID
  to providers. No personal collection data sent. Add IGDB attribution/link.

## Official references (verified 2026-09-25)
https://scandex.gamery.app/documentation/api/ (v2 schema, key, lookup)
https://scandex.gamery.app/documentation/pricing/ (currently free)
https://api-docs.igdb.com/ (fields, search, covers, limits, partnership)
https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#client-credentials-grant-flow
(form-encoded token BODY; IGDB examples use a query string, do not copy that)

## Acceptance and validation
- Mock contract fixtures: successful ScanDex+IGDB incl Wii UPC045496367619 and
  equivalent0045496367619; ensure these are labelled synthetic fixtures, not
  evidence of live coverage. 404/unmatched, source=user, missing optional fields,
  partial enrichment, ID/platform mismatch, auth/401-once, 429, bad JSON/types,
  oversized/slow/redirect transport, host/port/path restrictions, sanitized errors.
- Credential changes/races, token expiry/concurrent acquisition and title query
  escaping have meaningful focused tests. Routing/cache regression tests and
  no-credentials no-request test. Shared limiter exercised across both paths.
- Widget flow tests: settings save/replace/remove + storage failures; barcode
  failure -> title search -> console -> editable draft retains code; no save on
  selection; stale/disposed response ignored; manual/back/retry; repeated failures
  render without duplicate keys. Existing backup/personal-data invariants remain.
- Flutter analyze, dart format check, relevant tests, then full suite once after
  changes stabilize. Do not needlessly repeat the full suite after each small fix.
  Golden/render checks at390x844 and320x568 with textScale1.6 for new screens/settings.
- Build Android0.4.0+5, install -r on emulator if available and smoke new Settings
  and missing-key flow. Preserve existing library and any real keys. Synthetic
  secret persistence test is allowed only if no existing games keys; erase dummy
  values afterward. No real-key provider call unless user supplies credentials
  via approved private path. Do not claim live Wii barcode coverage without it.
- Existing build workaround: Flutter /Users/ghijs/development/flutter; Android SDK
  /Users/ghijs/Library/Android/sdk; JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home.
  Fresh Gradle --no-daemon --no-watch-fs succeeded previously. Follow evidence in
  prior build logs. Session may retain grants for ~/.gradle, ~/.pub-cache, Flutter
  bin/cache and flutter_tools/gradle/.gradle,/build. If denied, report exact needed
  permission; do not bypass sandbox/approvals.
- Place versioned APK under deliverables/lyberry-0.4.0-debug.apk with SHA256; root
  packages source after acceptance. Never overwrite0.3.xdeliverables.
- Report exact modified files, tests/commands/exits, build SHA, visual artifacts,
  known limitations, no-live-key status in REPORT-GAMES.md. On genuine block or
  interruption, checkpoint work and precise resume action. Otherwise complete
  internal implementation/test/debug loop and send one ready-for-review report.
