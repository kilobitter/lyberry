# ScanDex + IGDB games lookup - implementation report (0.4.0+5)

STATUS: **ready_for_review after the consolidated correction cycle
(`REVIEW-GAMES.md`).** All eight findings are implemented with targeted
regressions; 392 tests pass, analyze/format are clean, the renders and goldens
are current, and the rebuilt 0.4.0 APK is installed and smoke-tested. No real
provider call was made.

Workspace: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry`
Baseline: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/baselines/games-pre-040` (398 files)

## 1. What was built

| Layer | File | Behaviour |
| --- | --- | --- |
| Games transport | `lib/services/games/games_transport.dart` | HTTPS/443 only, **host + path + method allowlist** (`GET scandex.gamery.app/api/v2/lookup`, `POST id.twitch.tv/oauth2/token`, `POST api.igdb.com/v4/games`), userinfo rejected, redirects disabled, one whole-request deadline, body caps, sanitized `ProviderException`s that never echo a response body, URL query or header; `GamesEndpointLimits` holds the contract timeouts |
| ScanDex | `lib/services/games/scan_dex_client.dart` | `GET /api/v2/lookup?value=<scanned code>` (UPC leading zeros preserved) with the personal token as a **raw `Authorization` header**; 404 / `status: unmatched` / `igdb_metadata: null` are "no match"; positive-integer id validation; `source: user` flagged as community |
| Twitch | `lib/services/games/twitch_token_client.dart` | `POST /oauth2/token` with a **form-encoded body** (`client_id`, `client_secret`, `grant_type=client_credentials`), in-memory token only, expiry skew, concurrent acquisition deduplicated, credentials fingerprint, generation-guarded caching so an invalidation cannot be undone by a late exchange |
| IGDB | `lib/services/games/igdb_client.dart` | `POST /v4/games` with `Client-ID` + `Bearer`, explicit field list, fetch by exact id (`where id = N; limit 1;`) and title search (`search "..."; limit 20;`) with correct APICalypse quote/backslash escaping and input validation; per-platform release years only (never `first_release_date`, never another platform's year); developer/publisher mapping; cover URL built only from a validated `image_id` on `images.igdb.com`; one 401 refresh + retry, no loops; every request passes the injected shared limiter |
| Provider + catalog | `lib/services/games/games_lookup_service.dart` | One service implementing `MetadataProvider` (barcode) and `GameCatalog` (title search). Game hint: games first, general fallback only when empty/failed. Unknown non-ISBN: games + music before the general fallback. ISBN/book hints never reach games. Missing ScanDex credentials send **no request** (actionable setup error for an explicit game hint, silent for unrelated automatic lookups). Partial ScanDex candidate kept with a warning when IGDB is unconfigured, unavailable, missing the game, or disagrees about the platform. Candidates carry game+platform identity (`igdb:<gameId>:<platformId>`), platform-specific year, platform name, cover and source URL; title search returns one candidate per game/platform pair, deduplicated, ≤8 platforms per game and ≤60 candidates |
| Domain/routing | `lib/domain/lookup.dart`, `lib/services/metadata_service.dart` | New `ProviderRole.games` plus routing for game and unknown hints (see above) and `invalidateCache()` for credential changes |
| Credentials | `lib/services/keys/api_key_store.dart` | `CredentialKey` interface; new `GamesKeyProvider` (`scandex`, `twitchId`, `twitchSecret`) with stable persisted names, separate from the web keys so the groups cannot display the wrong fields; existing validation/readback/removal-failure behaviour reused |
| Settings | `lib/ui/screens/settings_screen.dart` | Generic `_CredentialSection`: "Web lookup keys" (unchanged keys/labels) and a new "Games lookup keys" group with masked inputs, Save/Replace/Remove, Saved/Not configured/Unavailable statuses, setup links (ScanDex docs, Twitch console, IGDB docs), IGDB/ScanDex attribution and the development-credentials explanation; a games change clears cached lookups and the in-memory token |
| Title search UI | `lib/state/game_search_controller.dart`, `lib/ui/screens/game_search_screen.dart` | Explicit submit only (button enabled from the field, never per keystroke), single request per submit, stale/disposed answers ignored, bounded results with the platform and year shown, `Use this` returns the chosen candidate, manual fallback, missing-key banner with "Open Settings" and no request when unconfigured |
| Entry point | `lib/ui/screens/candidates_screen.dart` | "Search games by title" for game or unknown hints, in the empty, failed **and** ready (unwanted matches) states; the chosen candidate travels back through the existing `LookupChoice` flow so the scanned code still reaches the editor |

Version: `pubspec.yaml` `0.4.0+5`, Settings shows `Lyberry 0.4.0`, User-Agent
family unchanged (`Lyberry/0.3`); `android/local.properties` refreshed for the
direct-Gradle build. `CoverDownloader` allowlist gained `images.igdb.com`.

## 2. Tests (all green)

`flutter analyze` -> `No issues found!`; `dart format --output=none
--set-exit-if-changed lib test` -> `129 files (0 changed)`; full suite
`flutter test` -> **369 tests, all passed** (0.3.1 had 313; this phase adds 56).
Logs: `evidence/games/analyze.log`, `format.log`, `full-test-suite.log`,
`test-files.log`.

| New test file | Tests | Covers |
| --- | --- | --- |
| `test/services/games/games_transport_test.dart` | 8 | allowlisted request, non-allowlisted path rejected, https enforced outside the test seam, userinfo/non-443 rejected, redirects not followed and credentials not replayed, byte cap, deadline, sanitized status mapping |
| `test/services/games/scan_dex_client_test.dart` | 5 | raw Authorization header, UPC leading zeros, 404/unmatched/missing metadata as no-match, community vs imported source, malformed ids/names/shapes, auth/quota sanitization |
| `test/services/games/twitch_token_client_test.dart` | 8 | form body (never a query string), caching, concurrent dedup, no request without credentials, expiry with skew, credential replacement, invalidation of a pending exchange, response shape/type validation, sanitized failures |
| `test/services/games/igdb_client_test.dart` | 8 | request fields/headers/query shape, developer/publisher/cover mapping, platform-specific years, one 401 refresh and no second retry, 429 without retry, title escaping + invalid input makes no request, malformed answers, cover-URL validation, shared-limiter spacing |
| `test/services/games/games_lookup_service_test.dart` | 15 | synthetic Wii UPC **and** its zero-padded equivalent, community = possible match, chosen-platform year only, platform mismatch keeps the ScanDex candidate, IGDB failure keeps the partial candidate, no-credential = no request (explicit vs silent), title search candidates/dedup/caps, in-flight invalidation discards the answer, invalidation clears the shared cache and lets new credentials work immediately, one limiter across barcode and title, routing (games first, general fallback, unknown non-ISBN, book/ISBN never reach games) |
| `test/ui/game_lookup_flow_test.dart` | 7 | title search keeps the scanned code and saves nothing, no request before explicit submit, missing-key banner + no request, disposed search ignores its late answer, unwanted matches still offer the search, book lookups do not, settings save/replace/remove + invalidation + storage failure without leaking the value |
| `test/golden/games_render_test.dart` | 5 | renders below |

## 3. Renders (visual QA)

In `docs/agent-work/lyberry/evidence/games/`:

| File | Shows |
| --- | --- |
| `games_title_search_390x844.png` | idle title search with the scanned code and privacy helper |
| `games_title_search_results_390x844.png` | two platform-specific candidates (`Wii | 2009`, `PlayStation 4 | 2013`), each with `Use this`, plus manual fallback |
| `games_title_search_320x568_scale1.6.png` | the same screen at 320x568 with 1.6x text |
| `settings_games_keys_390x844.png` | games credential group: statuses, inputs, setup links, attribution, privacy copy, version 0.4.0 |
| `settings_games_keys_320x568_scale1.6.png` | the same section at 320x568 with 1.6x text |

The earlier candidates/settings goldens were regenerated for the new button,
section and version label (`test/golden/goldens/p2_*.png`,
`settings_web_keys_*.png`, copies refreshed in `evidence/p2/` and
`evidence/web-lookup/`).

## 4. Build

```bash
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
  ./gradlew assembleDebug --no-daemon --no-watch-fs --console=plain \
    -Ptarget-platform=android-arm,android-arm64,android-x64 \
    -Ptarget=lib/main.dart -Pbase-application-name=android.app.Application \
    -Pdart-obfuscation=false -Ptrack-widget-creation=true \
    -Ptree-shake-icons=false
```

`BUILD SUCCESSFUL in 23s` (log `evidence/games/build-apk-0.4.0.log`), metadata
`versionName 0.4.0`, `versionCode 5`, `minSdk 24`, `targetSdk 36`.

| Artifact | Value |
| --- | --- |
| APK | `deliverables/lyberry-0.4.0-debug.apk` |
| Size | 176 181 212 bytes |
| SHA-256 | `ecf048d53409d9bcbdbffddd29510c18d2727e30ddf796be6fb1406a655f0a55` (+ `.sha256`) |

0.2.0, 0.3.0 and 0.3.1 APKs/checksums and root's source archives are untouched.

## 5. Emulator smoke (`emulator-5554`, Pixel 8a API 37)

| Step | Result |
| --- | --- |
| `adb install -r` 0.4.0 (pre-correction build) | `Success`, `versionName=0.4.0`, `versionCode=5`, launches cleanly |
| `adb install -r` 0.4.0 (final build, after trimming device caches) | `Success`; see Section 9 for the final artifact and re-check |
| Existing collection | unchanged: the database still holds exactly the one pre-existing copy (`items=1`, `pulled-lyberry-0.4.0.db`) |
| Games Settings group | rendered on device with all three providers `Not configured`, the setup links and the attribution (`device-02-settings-games-keys.png`, `ui-games-keys.xml`) |
| Synthetic ScanDex value | saved -> `Saved`, survived a force-stop/relaunch, removed -> `Not configured`, removal survived another restart; **no dummy credential left on the device** (`device-03..05`, `ui-games-status.xml`) |
| Missing-key title search | from a barcode with no matches, the candidates screen offered **Search games by title**; the screen showed the scanned code with the `KEYS NEEDED` banner, the privacy helper, a disabled submit for an empty field and the manual fallback (`device-06`, `device-07`) |
| Crash check | `fatal_or_anr_lines=0`; no real ScanDex/Twitch/IGDB request was made (no credentials were present for the search, and the key save path performs no lookup) |

## 6. Known limitations (honest coverage)

- **No live ScanDex coverage is claimed for the sample Wii UPC.** Root's
  independent check of ScanDex's public lookup page with UPC `045496367619`
  returned "No results found."; no authenticated API call was made from this
  task. The ScanDex/IGDB Wii path is exercised **only with synthetic fixtures**,
  which are not evidence of live coverage. This is exactly why the title search
  exists and why it is treated as essential for codes like this one.
- No real credentials were supplied, so no live IGDB or Twitch call was made and
  the token refresh/quota paths are fixture-tested only.
- iOS runtime behaviour is not exercised (no Xcode here); the games code is
  platform-independent Dart.
- Camera, gallery, file dialogs and backup/merge flows are unchanged and keep
  their previous evidence.
- One device-only detail was verified through widget tests rather than on the
  emulator: submitting an empty/blocked title search with no credentials (the
  device screenshot covers the banner and the disabled button).

## 7. Changed paths

New: `lib/services/games/games_transport.dart`,
`lib/services/games/scan_dex_client.dart`,
`lib/services/games/twitch_token_client.dart`,
`lib/services/games/igdb_client.dart`,
`lib/services/games/game_catalog.dart`,
`lib/services/games/games_lookup_service.dart`,
`lib/state/game_search_controller.dart`,
`lib/ui/screens/game_search_screen.dart`,
`test/services/games/*` (5 files), `test/ui/game_lookup_flow_test.dart`,
`test/golden/games_render_test.dart`, `test/support/fake_games.dart`.

Modified: `lib/domain/lookup.dart`, `lib/services/metadata_service.dart`,
`lib/services/keys/api_key_store.dart`, `lib/services/cover_downloader.dart`,
`lib/services/providers/json.dart`, `lib/app_services.dart`, `lib/main.dart`,
`lib/ui/screens/settings_screen.dart`, `lib/ui/screens/candidates_screen.dart`,
`test/support/fake_web.dart`, `test/support/test_support.dart`,
`test/golden/web_lookup_render_test.dart`, `test/golden/p2_render_evidence_test.dart`,
`pubspec.yaml`, `README.md`, regenerated goldens, plus
`deliverables/lyberry-0.4.0-debug.apk` (+ `.sha256`).

Not touched: `BRIEF-GAMES.md`, `ACCEPTANCE-GAMES.md`, `CHECKPOINT.md` and any
other root-owned document; 0.2.0/0.3.x deliverables.

## 8. Next checkpoint for Astra

1. Review the games clients against the contract (especially the transport
   allowlist, the ScanDex field mapping and the platform-mismatch fallback).
2. Decide whether the source package should include the new games files plus the
   refreshed goldens and `evidence/games/` (root owns packaging).
3. If a live check is wanted later, the user can add ScanDex/Twitch credentials
   in Settings on a device; the code path is ready, and the title search is the
   recommended route for codes ScanDex does not index.

## 9. Correction cycle (`REVIEW-GAMES.md`)

| # | Finding | What changed | Regression |
| --- | --- | --- | --- |
| 1 | Settings return blocked the search | `GameSearchScreen` now stores its catalog, `await`s the Settings route and re-reads `isConfigured` on return (save and removal both take effect); the title field is disabled while a search is in flight, and a query edit clears results from the previous title | `returning from Settings with a saved key enables the search`, `editing the title clears results from the previous search` |
| 2 | Match validation/schema | ScanDex accepts the documented `source: "import"` literal (`imported` tolerated) with the official v2 example shape; `IgdbClient.gameById` rejects a different game id; platform mismatches downgrade the ScanDex partial to `possible` and can never stay exact; a Unix-seconds `release_dates.date` becomes a UTC year when `y` is absent; provenance URLs are limited to IGDB HTTPS hosts without userinfo or a non-443 port | `the documented import literal and v2 example resolve`, `a different game id is rejected instead of substituted`, `a Unix-seconds release date becomes a UTC year`, `provenance URLs are restricted to IGDB https hosts`, `an IGDB id mismatch keeps a downgraded ScanDex partial` |
| 3 | Rate limiting at the HTTP boundary | New `GamesRequestGate` wraps **every** IGDB POST (including the 401 retry) with shared spacing (>=300 ms), a concurrency cap (<8, default 6) and cooldown; a 429 applies `Retry-After`/default cooldown to the shared limiter; the limiter is registered in `main`'s limiter map so Settings shows the games cooldown | `spaces consecutive requests`, `never exceeds the concurrency cap`, `a server cooldown blocks every later request`, `a 429 cooldown stops the next path from sending` |
| 4 | Credential invalidation races | `MetadataService` keeps a cache generation: an answer whose lookup started before `invalidateCache()` is never written to the cache; `GamesLookupService` rejects an invalidated enrichment instead of returning a stale partial, checks freshness before later stages and the retry, and Settings invalidates from a services object captured before the storage await (so a disposed route still invalidates); `TwitchTokenClient.invalidate` detaches pending work and `invalidateIf(generation:)` stops an old 401 from discarding a newer token | `an in-flight answer from before an invalidation is not cached`, `an invalidation during enrichment rejects the result`, `a stale 401 cannot discard a newer token`, `a pending exchange cannot survive invalidation` |
| 5 | Secret-bearing header errors | Token values are validated (printable, bounded) before becoming headers; `expires_in` must be a positive integer and the cache never outlives the reported lifetime (a 5 s token is not padded); `IoGamesTransport` validates header values itself and maps `FormatException`/unexpected failures to fixed sanitized messages, so a Dart `HttpHeaders` error cannot leak a token | `a malformed header value is rejected without echoing it`, `a control-bearing token is refused without echoing it`, `a short-lived token is never padded into a longer cache` |
| 6 | Keystore errors are not missing keys | `GamesLookupService` turns a credential read failure into a sanitized `unavailable` failure with a storage message (never "add your key"), keeps the ScanDex partial with an accurate warning when only the enrichment credentials fail, and the title screen shows a `CREDENTIALS UNAVAILABLE` banner for a read error | `a keystore read failure is not reported as a missing key`, `only the enrichment credentials failing keeps the ScanDex partial`, `a credential read failure is shown accurately` |
| 7 | Flow-test coverage | The flow test now goes scan -> manual code -> candidates -> title/platform -> editor -> save, asserting the prefilled barcode/title/platform, blank review/notes/rating, no write before Save, then persistence of exactly those values; a second test covers the manual fallback keeping the code. Cross-platform render fixtures were renamed to a clearly synthetic game so no impossible real release is implied | `a chosen game reaches the editor and saves only on demand`, `the manual fallback from title search keeps the scanned code` |
| 8 | Copy/evidence accuracy | Settings restores the optional Tavily/DeepSeek helper, adds actionable Twitch setup steps (2FA, confidential application, client ID/secret) and the games privacy wording now names the code/ScanDex and title/game-id/IGDB requests; the historical `evidence/p2` and `evidence/web-lookup` settings images were restored byte-identically from the pre-040 baseline, while current renders live in `evidence/games` and the test goldens | byte-identical SHA-256 comparison against the baseline copies |

### Verification after the corrections

`flutter analyze` -> `No issues found!`; `dart format --output=none
--set-exit-if-changed lib test` -> `132 files (0 changed)`; full suite
`flutter test` -> **392 tests, all passed** (369 before the cycle). Per-file log:
`evidence/games/test-files.log` (transport 9, gate 3, ScanDex 6, Twitch 11,
IGDB 11, games service 20, metadata cache 2, UI flow 12, renders 5).

### Final artifact

Rebuilt after the corrections and reinstalled:

| Artifact | Value |
| --- | --- |
| APK | `deliverables/lyberry-0.4.0-debug.apk` |
| Size | 201 039 582 bytes |
| SHA-256 | `06af1f2dcbc42600ff194d2b81989180dc74bf9e09127e9e6e29ddd16feac7ad` (+ `.sha256`) - superseded by the auth-race follow-up build in Section 10 |
| Metadata | `versionName 0.4.0`, `versionCode 5` |

Device re-check: install needed a `pm trim-caches` first because the emulator was
at 91 % disk usage (nothing was wiped); after that the final APK installed over
the existing data, launched, showed the games Settings group with the corrected
copy and links, kept the library (one copy) and logged `fatal_or_anr_lines=0`.
The Settings-return behaviour itself is proven by the widget regression, which
fails against the pre-correction code.

## 10. Narrow auth-race follow-up

The accepted correction bundle left one auth-race gap, closed here without any
broader refactor:

| Change | Detail |
| --- | --- |
| Freshness check after gate admission | `IgdbClient._post` now calls `_assertFresh()` **inside** the admitted `gate.run` closure immediately before `_transport.send`, so a credential change while a request was queued for a slot can no longer send with the old token |
| Freshness checks after storage awaits | `GamesLookupService.lookup` asserts the generation immediately after the ScanDex key read and after the Twitch credential read (including its failure path), before returning any partial or starting the enrichment request |
| No quota penalty for credential changes | Credential-change aborts in the service, `IgdbClient` and `TwitchTokenClient` now use `LookupFailureKind.unavailable`. Previously they used `cooldown`, which `MetadataService._run` treats as a quota-style failure and would have parked the now-registered IGDB limiter for 60 s on every key change |
| Malformed epoch guard | `_releaseYear` refuses an out-of-range Unix `date` (`> 9999-12-31T23:59:59Z`) and returns null instead of letting `DateTime` throw a `RangeError` |

### Regressions

| Test | What it proves |
| --- | --- |
| `a credential change while queued for a gate slot sends nothing` (IGDB client) | with a 1-slot gate, a request queued behind an in-flight one sends **zero** extra IGDB POSTs after the credentials change |
| `a huge Unix release date is ignored instead of throwing` | a malformed date yields no year and no exception |
| `invalidating during a delayed ScanDex key read sends no request` | zero ScanDex requests after a change during the key read |
| `invalidating during a delayed credential read sends no IGDB request` | zero IGDB requests after a change during the Twitch credential read; no partial is returned |
| `a credential change does not penalize the shared IGDB limiter` | through a real `MetadataService` with the IGDB limiter registered, the aborted lookup leaves `cooldownFor('igdb') == Duration.zero`, and an immediate fresh lookup reaches ScanDex/IGDB with no quota/cooldown failure |

**Before/after proof for the gate regression** (pre-fix state reproduced by
temporarily removing the post-admission check, file restored hash-identically):
`evidence/games/regression-before-gate.log` shows the test failing
(`Expected: ProviderException(unavailable)` but a game was returned, i.e. the
queued request *was* sent) and `regression-after-gate.log` shows it passing.

### Verification and final artifact

`flutter analyze` -> `No issues found!`; `dart format` -> `132 files (0
changed)`; full suite `flutter test` -> **397 tests, all passed** (392 before
this follow-up). Relevant suites re-run green: games transport/gate/clients/
service, metadata cache and UI flow (`evidence/games/test-files.log`,
`full-test-suite.log`, `regression-*.log`).

| Artifact | Value |
| --- | --- |
| APK | `deliverables/lyberry-0.4.0-debug.apk` |
| Size | 201 039 106 bytes |
| SHA-256 | `4d10b6e38f918c3acae045b24381b2a7c34fa2a7475b0ca147b8b66e1c236565` (+ `.sha256`) |
| Metadata | `versionName 0.4.0`, `versionCode 5` |

Short device smoke after the rebuild: install over the existing data succeeded,
the app launched as 0.4.0/5, the library still holds one copy, the games
Settings group renders with the corrected copy (including the Twitch 2FA setup
line) and `fatal_or_anr_lines=0` (`device-13`/`device-14` screenshots,
`ui-followup-settings.xml`).

**Coverage statement (no overclaiming):** these five regressions prove the
specific races above. They do not prove every possible credential or scheduling
interleaving; no live provider call was made and no real key was used.
