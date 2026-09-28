# Lyberry v1 — architecture and acceptance contract

Status: product requirements confirmed; visual direction selected 2026-09-23.
Root architect/reviewer: GPT-6 Astra. Implementation: installed astra_flash_builder role, DeepSeek V4.1 Flash via DeepSeek API.

## Objective and boundaries
Build a usable Flutter Android/iOS app for a personal collection of physical books, CDs, DVDs, Blu-rays, vinyl and games. Local storage is authoritative; no account, server, analytics, social features, wishlists, tags or lending in v1. Android is the first testing target. Future publication is a goal, not authorization to publish/sign/release now.

The user scans a barcode or types an ISBN/barcode, sees likely metadata candidates, chooses one, edits if needed, and saves an owned copy. Manual entry always works. Personal photo(s), half-star ratings, review and notes belong to each copy. Multiple copies are separate records, including when barcodes match.

## Evidence and workspace
No existing Flutter repo or Git repository. Baseline consisted solely of five existing design artifacts in ../lyberry-concepts; preserve them.
Project root: /Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry
Flutter installed at /Users/ghijs/development/flutter, version 3.41.6 / Dart 3.11.4 from its cached version metadata. Android SDK, adb and Xcode command are present; worker must discover actual build/device readiness.
No project .codex configuration discovered. Root session metadata shows gpt-6-astra / xhigh. Static doctor reports static-ready and pinned Flash route; actual inference not yet verified.

## Visual contract
Use ../lyberry-concepts/a-redline.png for layout, color, spacing and general styling. Use ../lyberry-concepts/c-monolith.png ONLY for the squared geometric brand/title type. Approximate that generated type with bundled Oxanium (SIL OFL; include license), semibold for Lyberry and major page headings. Use native Roboto/system sans for readable body text.
Palette: background #111416, raised surface #1B1F22, ink #F3F4EE, muted #A2A7AB, signal red #F24C3E, rule #363A3D. Mostly 4px corners, thin rules, air between sections, restrained red.
Home: compact Lyberry masthead + add action; Your collection and real copy count; search; wrapping medium tabs (All, Books, CDs, DVDs, Blu-ray, Vinyl, Games); recent-first two-column cover grid on normal phones; bottom Library / prominent Scan / Settings. No sample data on real first launch. Intentional empty and no-results states. Preserve cover aspect using contain/letterbox, not distortion.
At narrow widths or large text scaling, adapt to avoid clipped titles, inaccessible filters or overflow. Touch targets >=48 logical pixels, semantic labels, dark system UI, visible focus. Use bundled fonts offline; never fetch fonts at runtime. Grid uses actual photos/covers or tasteful medium-specific geometric placeholders; never bake a screenshot into UI.
Detail: metadata, rating, separate review and private notes, photo strip, edit, add another copy, delete with confirmation. New copy duplicates metadata/cover only, clears personal rating/review/notes/photos and gets a fresh ID.
Editor: medium+title required, creator, year, publisher, barcode/ISBN, description, platform (games optional), rating, review, notes and photos. All fetched data is editable.

## Architecture
Use straightforward Flutter layers: immutable domain models; injectable repository/services; SQLite data layer; a small ChangeNotifier/controller for UI state; reusable UI components. Avoid unnecessary code generation or framework layers.
SQLite via sqflite is durable storage. Tests use sqflite_common_ffi (real SQLite) and injected fakes at UI/service seams. Choose compatible stable package versions, commit lockfile as a file (do NOT git commit).
Mobile services: image_picker, mobile_scanner (bundled Android scanner for offline scanning), file_picker for import/export file selection (compatible maintained release), optionally share_plus for native share if needed. HTTP client injection. Minimal dependencies; no paid setup.

## Stable domain contract
MediaType stable serialized values: book, cd, dvd, bluray, vinyl, game.
MediaItem represents ONE OWNED COPY with:
- id: UUID v4 string, immutable identity; never barcode-derived
- medium: MediaType; title nonempty trimmed <=500 chars
- creator, publisher, description, platform: strings (empty allowed)
- year: nullable integer 1..9999
- barcode: optional normalized valid ISBN10/ISBN13/EAN13/EAN8/UPC-A as applicable; imported user metadata must be validated consistently
- rating: nullable double, 0.5..5.0 in increments of 0.5 (null = unrated)
- review, notes: strings, independent of provider metadata
- coverAssetId: optional attachment SHA256; photoAssetIds: ordered unique list
- source: optional provider ID + external record ID + HTTPS source URL (metadata provenance only)
- createdAt, updatedAt: UTC ISO8601 timestamps
String bounds: general short strings <=1000, description/review/notes <=20000 each; max20 personal photos per copy.
MediaAsset: immutable id=lowercase SHA256(raw bytes), MIME image/jpeg or image/png or image/webp, validated decoded raster bytes <=5 MiB, dimensions bounded <=20 megapixels. Store bytes in SQLite assets table rather than external file paths so copy+image import can commit atomically and exports are portable.
Persistent schema version1, foreign/relationship consistency enforced by repository. Transactions for multirow changes; no unique constraint on barcode. Repository must not silently recover DB failure by replacing real storage with an empty in-memory store.
Repository operations equivalent to list/get/save/createCopy/delete/merge/exportSnapshot, async. Interface naming may vary; semantics are fixed. Attachment import/save and copy rows must be atomic. No deletion of unreferenced assets needed in v1 if cleanup would complicate safety; document if retained.

## Backup / merge contract (phase 2)
One portable UTF8 JSON file, extension .lyberry.json, format:
{format:"lyberry", schemaVersion:1, exportedAt:<UTC>, items:[full MediaItem maps], assets:[{id,mimeType,dataBase64}]}.
IDs preserved across export/import; files contain all photos and cached covers referenced by exported items. No absolute local paths. Match ONLY by item ID, not ISBN/barcode/title. Incoming full item replaces matching local item including personal fields and timestamps, even if its timestamp is older. Missing local items remain untouched; no deletion propagation. Different IDs sharing barcode remain separate copies. Importing same file twice is idempotent.
Before DB writes validate entire file, known schema/format, field types/bounds, IDs, enums, timestamps, finite half-star ratings, duplicate item/asset IDs, base64, SHA256 and image MIME/decodability. Every referenced asset must be present in the backup. Reject malformed/future formats with useful human-readable errors; zero partial changes.
Bound input before parsing: <=100 MiB file, <=10000 items, <=10000 assets, <=60 MiB combined decoded images, <=5 MiB/image. Check base64 decoded size before allocating it; avoid unbounded image decode. Run expensive parsing/validation off UI isolate where practical. Export obeys same bounds and explains if exceeded; a failed export must not damage existing library/files.
Show preview counts for additions/updates and explain incoming personal fields replace existing ones. User taps Merge to apply a single atomic DB transaction; cancellation leaves library unchanged. Then show outcome.
Export via native save/share, import via picker. Handle cancellation, corrupt files, platform errors. No filesystem path traversal possible: backup assets are bytes, not extraction paths.

## Metadata contract (phase 2)
Provider interface with id, supported media, lookup(normalized identifier, optional medium hint) => candidates. Candidate has stable provider/external ID, suggested medium (nullable when uncertain), title, creator, year, publisher, description, platform, cover HTTPS URL, provenance and match kind exact/possible; no invented probability percentages.
Service coordinates providers, per-host throttling/cache, normalizes and validates code/checksum, deduplicates exact provider IDs and ranks code-exact matches before weaker ones. Normalize ISBN10->ISBN13 for routing; UPC12/EAN13 leading-zero equivalence should match.
Start free and key-free:
- Open Library search.json?isbn=...&fields=key,title,author_name,first_publish_year,cover_i,edition_key,publisher,isbn&limit=10. Use edition-aware lookup where feasible, don't pretend a work first-publish year is edition year. Exact ISBN candidate selection. Current books docs label old /api/books legacy; prefer current endpoints.
- MusicBrainz /ws/2/release/?query=barcode:<code>&fmt=json&limit=10 for CDs/vinyl (and releases when no hint). Parse media format to suggest CD/vinyl. Cover Art Archive thumbnail URL based on release ID. No credentials. <=1 request/sec, proper identifying User-Agent.
- UPCitemdb https://api.upcitemdb.com/prod/trial/lookup?upc=<code> as general fallback for DVD/Blu-ray/game/unknown and for other empty results. Parse items only, no offers/prices. Category/title hints are suggestions, always editable. Free service has quotas; report quota hit and permit manual entry.
When hint absent: ISBN prefix routes book first; other codes try music + general fallback as needed. Candidates preserve source distinctions (can be 1 or several); UI NEVER automatically saves even a sole candidate.
Timeout bounded ~10s/provider; network,429,5xx,malformed responses remain distinguishable from genuine no matches. Partial results remain usable with small source failure notice. Retry user-driven, no loops. Debounce camera callback and stop camera before lookup, resume only on return. Camera permission denied/restricted has manual-entry fallback. Android and iOS usage descriptions and INTERNET only as needed.
Library never needs network to browse/edit. Lookup sends identifier only, never notes/photos/review/library. Cover download only from safe public HTTPS: reject localhost/IP literal/private/link-local hosts; disable automatic redirects or validate every target; strict timeout/size/image type. Backup import performs NO outbound requests. Saved cover bytes cached locally when fetch succeeds, failure cannot block saving; local placeholder otherwise.
Network transport and clock injectable for deterministic fixture tests. Configure meaningful UA Lyberry/0.1 with real maintainer contact via build define when available; do not invent an email/domain. Surface contact setup as a release prerequisite. Low-volume development calls only; public/commercial usage terms need review before future publication.

## Acceptance by end of v1
1. Real persistent CRUD across DB close/reopen; all six categories, search/filter, newest first.
2. Add another copy keeps separate ID and clears personal fields; original untouched.
3. Photo import/capture persists; cancelled/denied picker safe; removal/update and Android lost-data recovery handled.
4. Real ISBN/manual/scanner lookup, candidate choice then editable save; validation/failure fallbacks; repeat detections cannot duplicate item.
5. Atomic export/import roundtrip including photos; incoming-wins updates, absent retained, copies preserved, idempotence, invalid input no mutations.
6. Dark Redline+Oxanium UI tested at phone width and large text scale; no overflow; empty/loading/error states.
7. flutter analyze and meaningful Flutter unit/widget tests pass; Android debug APK builds if environment allows. iOS project configured; attempt simulator build when available without signing/paid setup. Report actual evidence and hardware-only checks.
8. README launch/build/backup semantics/provider limits/privacy notes, architecture sources and font license; debug APK copied to deliverables/ when built.
No release signing, store upload, commits, push, deployment, credentials changes or global toolchain upgrades.

## Primary research
- https://openlibrary.org/developers/api — low-volume human lookup, caching, default 1rps; identify app/contact for regular use.
- https://openlibrary.org/dev/docs/api/search — search result work vs edition fields.
- https://openlibrary.org/dev/docs/api/books — ISBN/edition APIs, legacy warning.
- https://musicbrainz.org/doc/MusicBrainz_API — no API key, UA, noncommercial use, <=1rps.
- https://www.upcitemdb.com/wp/docs/main/development/getting-started/ — free /trial endpoint without keys.
- https://www.upcitemdb.com/wp/docs/main/development/plan/
- https://www.upcitemdb.com/wp/docs/main/development/api-rate-limits/
- https://pub.dev/packages/mobile_scanner — bundled Android scanner and iOS permissions.
- https://pub.dev/packages/image_picker — durable storage and Android lost-data handling.
- https://pub.dev/packages/sqflite — mobile SQLite/transaction support.
- https://github.com/google/fonts/tree/main/ofl/oxanium — bundled typeface and OFL.

