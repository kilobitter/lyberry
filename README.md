# Lyberry

Lyberry is an offline-first Android and iOS app for keeping a personal
collection of physical books, CDs, DVDs, Blu-rays, vinyl and games. Scan or type
a barcode, pick a metadata candidate, keep it as one owned copy, rate it, review
it, add private notes and photos of your own copy, and export the whole library
as one portable file.

Everything lives on the device. There is no account, no sync and no analytics.

## Features

- **Collection grid** with real copy counts, search, medium tabs and a
  newest-first two-column grid. Empty and no-results states are real states, not
  demo data.
- **Real barcode scanning** (`mobile_scanner`, bundled ML Kit on Android) with a
  camera lifecycle that pauses on app suspension and stops before a lookup.
  Repeated frames of the same code are debounced, so one scan is one lookup.
- **Manual entry always works**, with or without a camera or network.
- **Metadata lookup** from Open Library (books), MusicBrainz (CD/vinyl/releases)
  and the free UPCitemdb trial endpoint (DVD/Blu-ray/game/general fallback).
  Candidates are always shown, even when there is only one, with an exact/possible
  match label and no invented match percentages. Nothing is ever saved
  automatically, and every fetched field stays editable.
- **Per-copy personal data**: half-star rating, review, private notes and up to
  20 photos, all stored as bytes inside the library file.
- **Personal photo covers**: make any of a copy's own photos its cover through a
  dedicated preview with a draggable crop rectangle and quarter-turn rotation.
  The preview shows the EXIF-corrected, rotated image, so the framing you set is
  the framing that is saved; the work runs off the UI thread. Saving stores a
  separate derived cover: the original photo keeps its bytes and place in the
  photo list, its capture and location metadata are dropped from the derived
  image, and the photo can be cropped again from the untouched original.
  Removing the photo leaves the cover in place, and removing the cover keeps
  every photo.
- **Finished per copy**: books and DVD/Blu-ray copies carry a labelled
  **Finished** checkbox in the editor and a **Finished / Not finished** status
  on the detail page. It is personal, per-copy state: a new copy starts
  unfinished, editing metadata never changes it, and switching a copy to
  another medium hides the control without discarding the stored value.
- **Multiple copies** are separate records with separate identities, even when
  two copies share a barcode. "Add another copy" duplicates metadata and cover
  art, then clears rating, review, notes and photos.
- **Portable backup**: export one `.lyberry.json` file with every copy, asset and
  personal field, or import one through a preview that states exactly how many
  copies will be added or replaced.
- **Optional web lookup** for codes the free catalogues miss: an explicit
  "Search the web" action (or "Import from link") that reads public product
  pages, prefers JSON-LD `Product` data with a matching GTIN, and only asks a
  language model to extract from evidence that actually contains the code. It
  uses the user's own Tavily and DeepSeek keys and never runs on its own.
- **Optional game lookup**: a game barcode is identified with ScanDex and
  enriched with IGDB metadata, and **"Search games by title"** identifies a game
  by name when a barcode has no record. The scanned code travels into the
  editable copy either way.
- **Games platform filter**: while the Games tab is selected, a Platform
  dropdown offers every console named on a saved game — trimmed, deduplicated
  case-insensitively and sorted alphabetically — and combines with the text
  search as an AND. Options come from the whole games library rather than the
  current results, the selection resets when you leave Games or clear the
  filters, and the control is disabled when no saved game names a platform.

## Setup and run

Flutter 3.41.6 / Dart 3.11.4 (the versions this project was built and tested
with):

```bash
flutter pub get
flutter run                      # device or emulator
flutter build apk --debug        # Android debug APK
flutter build ios --simulator    # iOS simulator build (macOS + Xcode)
```

Tests, formatter and analyzer:

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter test test/golden --update-goldens    # refresh render evidence
```

Optional build define for MusicBrainz etiquette:

```bash
flutter build apk --dart-define=LYBERRY_CONTACT=you@example.org
```

MusicBrainz asks clients to identify themselves. Without the define, Lyberry
sends `Lyberry/0.2 (personal media collection app)`. Add a real contact address
before any public release; the app never invents one.

## Architecture

| Layer | Files | Responsibility |
| --- | --- | --- |
| Domain | `lib/domain/` | Immutable `MediaItem` (one owned copy), content-addressed `MediaAsset`, `MediaType`, barcode/identifier normalization, validation rules, `LibrarySnapshot` + hardened `SnapshotCodec`, `ImageInspector` |
| Data | `lib/data/` | `sqflite` schema v2 with an in-place v1 upgrade, injected `DatabaseFactory`/`DatabaseLocation`, `SqliteMediaRepository` (atomic item + asset writes, search, copy/delete, snapshot export/merge, bounded BLOB reads) |
| Services | `lib/services/` | `HttpTransport`, provider adapters, `MetadataService` (limits, caching, partial results), `CoverDownloader`, `BackupService`, `ScanCoordinator`, `PhotoSource`, `ImageIngest` |
| State | `lib/state/` | `LibraryController` (collection state, bounded asset LRU), `LookupController` (one lookup), `ItemDraft` (editor form) |
| UI | `lib/ui/` | Redline theme with bundled Oxanium, home/detail/editor/scan/candidates/merge-preview/settings screens |

**Storage.** One SQLite file (`lyberry.db`) holds `media_items` and
`media_assets`. Images are BLOBs keyed by the lowercase SHA-256 of their bytes,
so identical photos collapse into one row and an item's images are never
external file paths. Item rows and their new assets are written in a single
transaction. On Android the whole BLOB is never put in a cursor: metadata is
read first and the payload is reconstructed from 256 KiB `substr` slices, for
both display and export.

Schema 2 added the `is_finished` flag (INTEGER, 0/1, default 0). An existing
library is upgraded in place with a single transactional `ALTER TABLE … ADD
COLUMN`: every row, timestamp, index, asset and foreign-key relationship is
kept, and existing copies simply become "not finished". A file from a newer
schema is refused rather than replaced, and the app never recreates a library to
make a migration pass.

**Images.** Ingestion checks the byte cap, sniffs the container, reads the
dimensions from the PNG/JPEG/WebP *header*, enforces the megapixel bound,
rejects animation, then decodes exactly one static frame with the same decoder
whose metadata was inspected. A compressed pixel bomb is therefore refused on
its declared size rather than after a huge allocation. Write boundaries
re-verify that a new asset's digest, MIME type and dimensions match its bytes;
assets already stored are trusted and not decoded again.

`MediaAsset` has exactly one validating constructor, `MediaAsset.fromBytes`,
which derives the SHA-256 id, MIME type and dimensions from the bytes and can
only be produced by that closed path. The plain constructor describes bytes from
elsewhere (a hand-built object, an imported payload or our own database row) and
is deliberately *not* marked verified, so the repository still checks digest,
MIME type and dimensions before such an asset can be written.

## Copy identity and merge semantics

- An item's identity is its UUID v4 `id`. It is never derived from a barcode, a
  title or anything else the user can edit.
- One item row is one owned physical copy. Two copies of the same barcode are
  two items with two ids.
- Import matches **only** on item id. An incoming item replaces the local item
  with that id, including rating, review, notes, the finished flag, photos,
  provenance and both timestamps — even when the incoming data is older.
- Local items that are not in the file are left untouched. Nothing is deleted by
  an import. Importing the same file twice is idempotent: second time reports 0
  additions and no new assets.

## Backup format and limits

```json
{
  "format": "lyberry",
  "schemaVersion": 2,
  "exportedAt": "2026-09-24T10:00:00.000Z",
  "items": ["...full MediaItem maps, including a boolean isFinished..."],
  "assets": [{ "id": "<sha256>", "mimeType": "image/jpeg", "dataBase64": "..." }]
}
```

Exports are written as schema 2 so an older build cannot silently drop the new
personal field. This build imports schema 1 and 2: a schema 1 file predates the
flag and imports as "not finished", while a schema 2 file must state
`isFinished` as a boolean. A present-but-wrong value (null, string or number) is
rejected in either version, and the import stays atomic: a malformed file writes
nothing. Imports keep the existing incoming-wins rule, so a schema 1 file resets
the flag to false for the copies it contains.

Export and import both enforce:

| Limit | Value |
| --- | --- |
| File size | 100 MiB |
| Items | 10 000 |
| Assets | 10 000 |
| One image | 5 MiB |
| All images combined | 60 MiB |
| Photos per copy | 20 |

Import validation happens before anything is written: strict schema version,
canonical UTC timestamps, strict `source` structure, unique item/asset ids,
canonical base64 with decoded sizes checked before any allocation, every
referenced asset present, SHA-256 matching the id, and the bytes decoding as one
static JPEG/PNG/WebP image. Any problem aborts the whole import with a readable
message and zero partial changes. Export reads from one SQLite transaction so a
backup is internally consistent, and both encoding and decoding run on a worker
isolate that receives only the snapshot, the text and the limits. The payload is
built by encoding each element with the real JSON encoder and counting its exact
UTF-8 size as it is appended, so an oversized backup is refused before the whole
string exists and a valid payload is never rejected on a rough estimate.

Unreferenced image rows are intentionally **not** deleted: deleting bytes that a
later merge might still reference is riskier than keeping them, so the library
file only grows.

## Providers and privacy

| Provider | Used for | Free-tier behaviour |
| --- | --- | --- |
| Open Library | ISBN-10/13 books, edition-aware year | ~1 request/second, low-volume use |
| MusicBrainz | CD/vinyl/release barcodes | ~1 request/second, identifying User-Agent required |
| UPCitemdb (trial) | DVD/Blu-ray/game/general fallback | 100 lookups/day, 6/minute, one request per 10 seconds |

Lyberry spaces calls per provider, honours `Retry-After` and rate-limit reset
headers as a cooldown, never retries automatically, and caches completed lookups
so a repeated scan does not spend quota again. A provider that fails is reported
as a partial failure; other providers' results stay usable, and manual entry is
always available.

Only the scanned or typed code leaves the device during a lookup. Notes,
reviews and photos are never sent to a provider, and importing a backup makes no
network requests. Exporting a backup is an explicit action that *does* put your
notes and photos in the file you choose, so keep that file somewhere you trust.
Cover art is downloaded only after
the user picks a candidate and only from an allowlist of public HTTPS hosts on
port 443 (`covers.openlibrary.org`, `coverartarchive.org`, `archive.org` and its
subdomains, `m.media-amazon.com`, `images-na.ssl-images-amazon.com`,
`i.ebayimg.com`, `i5.walmartimages.com`), with every redirect re-validated,
no userinfo/IP-literal/private/loopback targets, capped redirects, a bounded
timeout, a byte cap, and a static-image check. A failed cover download never
blocks saving. Manual entry always works: typing a code, or adding a copy
without any lookup, so a slow or cooling-down provider never blocks the library.

### Live provider smoke (opt-in)

The adapters can be checked against the real endpoints with a small host-side
script that uses the same transport and throttling as the app and sends three
public sample codes:

```bash
dart run tool/live_provider_smoke.dart
```

It appends the result to `docs/agent-work/lyberry/evidence/p2/live-smoke.log`.
Latest run in this environment:

| Provider | Code | Result |
| --- | --- | --- |
| Open Library | 9780306406157 | `network` - `Failed host lookup: 'openlibrary.org'` (this environment's DNS does not resolve that host; `curl` fails the same way) |
| MusicBrainz | 0724384654726 | OK in 165 ms, 1 candidate, exact barcode match, year 1998 |
| UPCitemdb | 5051892202657 | OK in 431 ms, 1 candidate, exact code match |

The Open Library adapter itself is covered by deterministic HTTP fixtures; only
its live host is unreachable here.

## Web lookup (optional, paid providers)

The free catalogues stay the default. When a code is not in them, the lookup
screen offers two explicit actions:

| Action | What it does | Key needed |
| --- | --- | --- |
| Search the web | Tavily Search with the quoted canonical code (UPC padded to EAN-13, ISBN-10 mapped to ISBN-13) plus the medium hint; then up to three public product pages are fetched | Tavily |
| Import from link | Reads one pasted public https product page | none for structured data, DeepSeek for plain text |

Retrieval order is always the same: safe direct HTML fetch of at most three
unique public pages, JSON-LD `Product` extraction first (a product counts only
when the code sits on that same node's own GTIN fields), and extraction by
DeepSeek only when no structured record matched. DeepSeek never sees a page that
does not contain the scanned code, evidence is capped at 12 KiB per page /
36 KiB total, and every returned field, quote, source id, type and size is
re-validated before a candidate exists. A structured product with its own
matching GTIN is labelled **Exact code match**; an AI result is always a
**Possible match** the user must review.

Keys are entered in Settings and stored in the platform keystore / keychain
(Android Keystore, iOS `ThisDeviceOnly` keychain item). They are excluded from
cloud backup and device transfer by `android/app/src/main/res/xml/backup_rules.xml`,
`android/app/src/main/res/xml/data_extraction_rules.xml` and the iOS
`Runner.entitlements`. Keys never appear in a library backup, a log, an error
message or a screenshot.

What leaves the device: the code and the medium hint go to Tavily; the code plus
public page excerpts go to DeepSeek; a pasted link may be fetched by its site or
by Tavily Extract. Notes, reviews, photos, ratings and the rest of the library
are never sent, and page text is treated as untrusted data (instructions inside
a page are ignored, and quotes must verify against the supplied evidence).
Requests are only made when the user taps an action, at most one search, one
extract and one extraction per action, with no automatic retries. Direct page
fetches are restricted to public HTTPS on port 443: no userinfo, no literal IP
hosts, no loopback/private/link-local/CGNAT/documentation/mapped addresses, DNS
results are validated and **pinned**, and the pinned TCP connection is upgraded
in-process with `SecureSocket.secure(... host: <original host>)` so SNI and
certificate validation still apply (Dart's `HttpClient` does not add TLS on top
of a `connectionFactory` result). Every redirect hop is re-validated, proxies are
disabled, and no credentials or cookies are ever sent to a page.

Tavily and DeepSeek are paid third-party services billed to the user's own keys;
Lyberry has no backend and no bundled key. The Settings screen explains this
before a key is used.

## Games lookup: ScanDex + IGDB (development credentials)

Games use their own credentials group in Settings, kept in the same OS
keystore / keychain as the web keys and never written to a backup, log, export,
screenshot or the database:

| Credential | Used for | Where to get it |
| --- | --- | --- |
| ScanDex API token | Identifying a game barcode (`GET /api/v2/lookup`, raw `Authorization` header) | <https://scandex.gamery.app/documentation/api/> |
| Twitch client ID + secret | Exchanging a Twitch app token for IGDB (`POST /oauth2/token`, form body) | <https://dev.twitch.tv/console/apps> |

Flow: a game barcode goes to ScanDex; a match is enriched with IGDB by exact
game ID (`POST /v4/games` with an explicit field list). Releases are mapped per
platform, so a chosen console never borrows another platform's year, and a
ScanDex platform that IGDB does not list keeps the ScanDex candidate with a
warning instead of silently becoming a different console. A trustworthy ScanDex
title/platform candidate is still offered when IGDB is unavailable or
unconfigured. When a barcode has no record, **Search games by title** sends the
typed title to IGDB and offers one candidate per game/platform pair; the user
picks the console and the scanned code is preserved into the editor.

Privacy and limits: a barcode lookup sends the code to ScanDex and the game ID
to IGDB; a title search sends the typed title to IGDB. Nothing from the
collection is sent. Requests are limited to the fixed ScanDex/Twitch/IGDB
endpoints (HTTPS, port 443, redirects disabled, one whole-request deadline,
byte caps, sanitized errors), the IGDB limiter is shared by barcode and title
lookups (>=300 ms spacing, <=4 req/s, bounded concurrency, 429 cooldown) and
credentials never appear in logs, URLs or errors. Attribution: game metadata by
IGDB, barcode identification by ScanDex.

**This build is a personal development setup**, not a public release: each user
supplies their own developer credentials. A published app should move the shared
credentials and the Twitch token exchange to a server-side proxy.

**Coverage note (2026-09-25):** an unauthenticated check of ScanDex's public
lookup page with the sample Wii UPC `045496367619` returned "No results found.",
so no live ScanDex coverage is claimed for it; the Wii ScanDex/IGDB contract is
exercised with synthetic fixtures only. Title search is the fallback that matters
for such codes.

## Movie lookup: UPCMDB (own API key)

DVD and Blu-ray codes use their own credential group in Settings, kept in the
same OS keystore / keychain as the web and game keys and never written to a
backup, log, export, screenshot or the database:

| Credential | Used for | Where to get it |
| --- | --- | --- |
| UPCMDB API key | Identifying a DVD/Blu-ray barcode and searching films by title | <https://upcmdb.com/pricing> |

Flow: a DVD/Blu-ray barcode is sent to `GET /api/v1/lookup/:upc` on the
documented Cloud Functions base
`https://us-central1-upcmdb-cbae5.cloudfunctions.net`. A UPC-A, or an EAN-13
that is the leading-zero form of a UPC-A, uses that single call; any other
EAN-13 uses `GET /api/v1/lookup/ean/:ean` unchanged, so a European code is never
truncated to a UPC. A returned record must carry the requested code (or its
documented equivalent) before it counts as an exact match; a record with no code
evidence is offered as a possible match only. **Search movies by title** sends
the typed title and optional four-digit year to `GET /api/v1/search`, always
returns possible matches, and leaves the code that was actually scanned in the
editor.

Privacy and limits: only the barcode, or the typed title and year, is sent;
nothing from the collection is. Requests use a fixed HTTPS host and route
allowlist with redirects disabled, one whole-request deadline, a 1 MiB cap,
sanitized errors, one local request per second shared by the barcode and title
paths, and honoured 429 cooldowns; the key never appears in a URL, log or error.
A cover URL is kept only when the existing cover-downloader policy accepts it,
and an external IMDb rating is shown as clearly labelled description text - it
never becomes the user's own rating, review or notes.

**Publishing consideration:** UPCMDB's free hobby tier allows 500 requests a
month and commercial use is on a paid plan. This build performs no purchase or
account setup; a published app needs its own plan and credentials, or a
server-side proxy, rather than shipping a shared key.

**Coverage note (2026-09-26):** UPCMDB's public demo route answered with a
Cloudflare browser-signature denial for the sample codes tried, so live coverage
is **unknown**, not "no match". No authenticated UPCMDB request was made from
this task. The adapter is validated against deterministic fixtures covering the
documented flat record and the `{status, data}` envelope; title search is the
fallback that matters for such codes.

## Fonts

Oxanium (`assets/fonts/oxanium/Oxanium-Variable.ttf`) with its SIL Open Font
License 1.1 (`assets/fonts/oxanium/OFL.txt`), downloaded from the official Google
Fonts repository (`ofl/oxanium`) and bundled offline. Body text uses the platform
sans (Roboto on Android). Fonts are never fetched at runtime.

## Validation status

- **0.7.0+9 photo covers**: 78 focused Flutter tests, 3 crop renders and 144
  pixel/safety checks passed; Dart analysis/format clean. Full suite deliberately
  skipped for this release at the user's request. Fresh three-ABI debug APK:
  `deliverables/lyberry-0.7.0-debug.apk`. Installed over the existing emulator
  library without data loss; gallery, crop, rotation, save/restart and Cancel
  verified. Original photo retained separately from the derived cover. iOS and
  live camera capture were not exercised. See
  `docs/agent-work/lyberry/ACCEPTANCE-PHOTO-COVER.md`.

- `flutter analyze`, `dart format --set-exit-if-changed` and the full
  `flutter test` suite pass for **0.6.0**: **513 tests** (the 485-test 0.5.0
  baseline plus 26 finished-flag tests and 2 new renders), the focused suite
  passed 63 tests, the format check reports `151 files, 0 changed`, and all 95
  historical render hashes are unchanged. Evidence is in
  `docs/agent-work/lyberry/evidence/finished/` (`finished-focused.log`,
  `finished-full-suite.log`, `finished-analyze.log`,
  `finished-format-check.log`, `finished-final-commands.json`,
  `render-preservation.json`).
- `flutter analyze`, `dart format --set-exit-if-changed` and the full
  `flutter test` suite pass for **0.5.0**: **485 tests**, including the movie
  service/transport/UI suites and the five new renders. The correction run is
  recorded in `docs/agent-work/lyberry/evidence/movies/correction-*.log`
  (focused 80 passed, analyzer clean, format 147 files / 0 changed, full suite
  485 passed) with the historical-evidence check in `historical-images.txt`
  (90 checked, 0 restored). Authenticated UPCMDB coverage and iOS runtime
  remain unverified.

- `flutter analyze` and the full `flutter test` suite pass for **0.4.1**:
  **413 tests** (the 397-test 0.4.0 baseline plus 13 platform-filter
  unit/widget tests and 3 platform-filter render tests) across domain,
  services, SQLite data, web lookup, games lookup, widget and golden suites.
  Platform-filter logs and renders are in
  `docs/agent-work/lyberry/evidence/platform-filter/`; games logs are in
  `docs/agent-work/lyberry/evidence/games/`, web/hotfix logs in
  `docs/agent-work/lyberry/evidence/web-lookup/` and
  `docs/agent-work/lyberry/evidence/web-error-widget/`, older runs in
  `docs/agent-work/lyberry/evidence/p2/`.
- Formatting is clean (`dart format --set-exit-if-changed lib test` reports
  `0 changed`). Run it as `dart --suppress-analytics format …`: in a
  network-restricted shell a bare `dart format` does the work and then exits 1
  because its analytics upload throws, which is an environment artifact rather
  than a formatting difference.
- The **0.6.0** debug APK is `deliverables/lyberry-0.6.0-debug.apk`, SHA-256
  `0d2804a8a6844f6d42eff3c18c48a6929a9c2c664b66f0de9b29337f684d9668`
  (`versionName 0.6.0`, `versionCode 8`, 176 257 848 bytes), from a fresh
  `./gradlew assembleDebug --no-daemon --no-watch-fs` build
  (`BUILD SUCCESSFUL in 22s`). ZIP integrity passed and all three native
  libraries (`arm64-v8a`, `armeabi-v7a`, `x86_64`) are present
  (`docs/agent-work/lyberry/evidence/finished/finished-android-build.log`,
  `apk-badging.txt`, `apk-verification.txt`). It adds the per-copy finished
  flag; the earlier **0.5.0** (UPCMDB movies), **0.4.1** (Games platform
  filter), **0.4.0** (ScanDex/IGDB games lookup), 0.3.1, 0.3.0 and accepted
  0.2.0 APKs are all kept in `deliverables/`.
- The **0.5.0** debug APK is `deliverables/lyberry-0.5.0-debug.apk`, SHA-256
  `52f986e09d8c760550a1ed723873b3b5e407fa802161dc993daa7d8002bdd01f`
  (`versionName 0.5.0`, `versionCode 7`, 176 255 296 bytes), built with the same
  `./gradlew assembleDebug --no-daemon --no-watch-fs` recipe from `android/`
  (fresh build `BUILD SUCCESSFUL in 20s`). ZIP integrity passed and the APK
  carries all three native libraries (`arm64-v8a`, `armeabi-v7a`, `x86_64`);
  evidence is in `docs/agent-work/lyberry/evidence/movies/`
  (`correction-android-build.log`, `apk-badging.txt`, `apk-verification.txt`).
  It adds the UPCMDB movie lookup and title search. One build-metadata note for
  the record: the first Gradle build of this version still produced a 0.4.1
  artifact because the generated `android/local.properties` had not been synced
  from `pubspec.yaml` (a direct Gradle build does not do that); the two
  generated version properties were corrected to `0.5.0` / `7` and this
  verified APK comes from the rebuild. 0.4.1 (Games platform filter), 0.4.0
  (ScanDex/IGDB games lookup), 0.3.1, 0.3.0 and the accepted 0.2.0 APKs are all
  kept in `deliverables/`.
- The **0.4.1** debug APK is `deliverables/lyberry-0.4.1-debug.apk`, SHA-256
  `63dc4d555ed4abdad8e604929311e9053a10f272a4b4c19592e6c5f07a4ebe0a`
  (`versionName 0.4.1`, `versionCode 6`, 201 059 210 bytes), built with the
  same `./gradlew assembleDebug --no-daemon --no-watch-fs` recipe from
  `android/`. It adds the Games platform filter; 0.4.0 (ScanDex/IGDB games
  lookup and title search), 0.3.1 (repeated-failure widget hotfix), 0.3.0 and
  the accepted 0.2.0 APKs are all kept in `deliverables/`.
- The **0.4.0** debug APK is `deliverables/lyberry-0.4.0-debug.apk`, SHA-256
  `4d10b6e38f918c3acae045b24381b2a7c34fa2a7475b0ca147b8b66e1c236565`
  (`versionName 0.4.0`, `versionCode 5`, 201 039 106 bytes), built with
  `./gradlew assembleDebug --no-daemon --no-watch-fs` from `android/`.
- **No 0.6.0 device smoke:** `emulator-5562` remained offline, so this
  release's installation, launch and device-library preservation were not
  exercised. No device data changed. The schema migration passed populated
  fixture tests; iOS runtime remains untested. Evidence:
  `docs/agent-work/lyberry/evidence/finished/device-smoke.txt`.
- **No 0.5.0 device smoke:** only `emulator-5562` was present and it stayed
  offline, so the 0.5.0 install/launch, foreground and library-preservation
  checks were not performed (`docs/agent-work/lyberry/evidence/movies/device-smoke.txt`).
  Camera capture, gallery picking, native file dialogs and iOS runtime remain
  unverified.
- 0.4.1 installed over the existing data on `emulator-5554` (Pixel 8a API 37):
  the Games tab shows the Platform control under the medium tabs, tapping the
  disabled control opens nothing and logs no exception, returning to All
  removes it, and the collection is unchanged (`items = 1`). The post-review
  correction was reinstalled and re-checked the same way. Device evidence is
  in `docs/agent-work/lyberry/evidence/platform-filter/device-*.png` and
  `device-04-lyberry.db`; see `REPORT-PLATFORM-FILTER.md`.
- On `emulator-5554` (Pixel 8a API 37) 0.3.1 installed over the existing data
  (`versionName 0.3.1`, `versionCode 4`), launched cleanly with the one-copy
  test collection intact, and Settings shows `Lyberry 0.3.1`. The 0.3.0 key
  lifecycle and no-key flow evidence is in
  `docs/agent-work/lyberry/evidence/web-lookup/device-*.png`; the 0.3.1 install
  screenshots are in
  `docs/agent-work/lyberry/evidence/web-error-widget/`.
- The key-free production probe against two real product pages now returns
  HTTP 200 with structured products (iMusic "Matrix", Reway "Wii Sports
  Resort"); the earlier plaintext-to-443 defect is fixed and covered by a local
  TLS regression. Live Tavily/DeepSeek calls and iOS runtime behaviour remain
  untested; see `REPORT-WEB-LOOKUP.md`.
- MusicBrainz and UPCitemdb were live-validated with public sample codes (see
  above); Open Library is fixture-validated because its host does not resolve
  here.
- Renders in `docs/agent-work/lyberry/evidence/p2/` and
  `docs/agent-work/lyberry/evidence/web-lookup/` were generated by the golden
  tests at 390x844 and at 320x568 with 1.6x text.
- Android Studio's Device Manager launched a Pixel 8a API 37 emulator. The debug
  APK installed and opened on it; see `docs/agent-work/lyberry/REPORT-EMULATOR.md`
  for the on-device checks. Direct emulator launch from this task's sandbox is
  blocked by host permissions, but the running device is accessible through adb.
  Camera capture, gallery picking, native file dialogs and iOS runtime behaviour
  still need device testing. `xcrun simctl` is not installed. Provider adapters
  are validated against deterministic HTTP fixtures; the live endpoints are not
  exercised by the automated suite.
