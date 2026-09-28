# Astra review — changes requested (2026-09-25)

Reviewed actual patch against games-pre-040, new clients/service/controller/UI,
changed settings/routing/composition, tests, 369-test/analyzer/build logs and two
rendered screens. The overall design fits; consolidated corrections below are
required before acceptance. No root rerun of the full suite.

1. **Settings return blocks title search.** GameSearchScreen reads isConfigured
   once. Open Settings uses an unawaited push; returning after saving credentials
   leaves _configured=false and _submit refuses forever. Await the route and
   re-read state while preserving title/code; handle removal too. Add a widget
   regression using the same screen before/after configuration. Also either
   disable editing during an in-flight title search, or invalidate the old result
   on query edits so results for an old title cannot appear under a new title.

2. **Match validation/schema.** ScanDex documents `source: "import"`, not
   `"imported"`; current synthetic fixtures hide this mismatch. Parse/document
   the current literal and test the official v2 example. IgdbClient.gameById
   currently returns the first parsed game without checking its ID: reject a
   different ID, preserving a warned ScanDex partial where appropriate. A
   platform/ID disagreement must never retain MatchKind.exact on the partial;
   explicitly downgrade to possible. When release_dates.y is absent, convert
   date as Unix seconds to UTC year (jsonYear treats it as a year and drops it).
   Keep no wrong-platform fallback. Restrict IGDB provenance URLs to IGDB HTTPS
   hosts without userinfo/non443 ports, rather than accepting any https URL.

3. **Rate limit contract is not implemented at the HTTP boundary.** _query
   calls guard before token acquisition, so a slow shared token exchange can
   bunch several later IGDB POSTs; the 401 retry calls _post without any guard.
   No concurrency cap is present. 429 in title calls or partial enrichment never
   penalizes the shared limiter (games limiter is also absent from main's map).
   Apply shared request spacing + bounded concurrency directly around each IGDB
   POST including retries, and apply Retry-After/default cooldown for429 before
   returning warnings/errors. Expose cooldown to Settings if retained there.
   Test actual fake-transport send times for overlapping calls with delayed
   token acquisition + a401 retry, and verify a429 on either path prevents the
   next path from sending. Preserve short responsive error handling.

4. **Credential invalidation races.** MetadataService.invalidateCache only clears
   the cache: a pre-change lookup (e.g. unconfigured games already returned empty,
   music/general still pending) can repopulate that cache after keys are saved,
   hiding games for12h. Add an acceptance/cache generation check at the service
   layer. GamesLookupService catches its own stale-generation exception during
   enrichment and returns a stale partial candidate; reject invalidated results
   instead. Guard before subsequent network stages and401 retry so a removed
   credential cannot start a new token exchange/IGDB call; old401 must not
   invalidate a newer token. TwitchTokenClient.invalidate must detach old
   _pending so an immediate same-credentials retry doesn't join stale work.
   Settings save/remove must invalidate even if the route was disposed while
   storage awaited; capture services before await and invalidate independently
   of mounted UI state. Test these specific races, not just clear() in isolation.

5. **Secret-bearing header errors can escape sanitization.** Twitch accepts any
   nonempty returned token; IoGamesTransport only catches selected exception
   types. Dart HttpHeaders._validateValue throws FormatException including the
   whole invalid header value (SDK http_headers.dart:688+); MetadataService then
   interpolates arbitrary error text. Reject malformed/oversized/control-bearing
   tokens, validate bearer response type and positive integer expires_in, never
   cache beyond actual lifetime (current lower clamp60 can reuse a5s token for30s).
   Sanitize games transport's unexpected/header-encoding failures, and ensure
   client credential/header validation cannot echo user values. Add a real local
   transport test using synthetic malformed Authorization and a token-response
   test with a control-bearing sentinel, asserting no sentinel in surfaced error.
   This is a concrete secret-handling issue, not permission to broaden unrelated
   transports or security infrastructure.

6. **Keystore errors are not missing keys.** GamesLookupService._read catches all
   errors and returns null. Surface a sanitized unavailable/read failure instead
   of telling the user to add already-stored credentials. Keep partial ScanDex
   metadata when only enrichment credentials cannot be read, with accurate
   warning. isConfigured failures should produce unavailable/setup status
   accurately, not silently claim no key. Add focused tests.

7. **Flow test overclaims its coverage.** 'title search keeps the scanned code
   and saves nothing' only checks the search screen vanished; it never receives
   the choice into an editor or inspects a draft/repository. Exercise actual scan
   or manual-code -> candidates -> title/platform -> editor, assert barcode,
   platform, metadata and blank personal fields; assert no write until Save,
   then persistence of the chosen values. Include back/manual. Existing suite
   support for scan/editor can be reused. Render fixtures show an impossible
   Wii Sports Resort PS4 release: use clearly synthetic game names for such
   cross-platform fixtures or a real appropriate game, without implying coverage.

8. **Copy/evidence accuracy.** Keep setup instructions actionable (Twitch account
   2FA, register confidential application, client ID/secret, official links).
   Existing top-level privacy paragraph still claims only scanned/typed codes;
   include title/game-ID requests. Restore useful optional Tavily/DeepSeek helper
   removed when sharing credential UI; public-release proxy detail can live in
   README with concise personal-credentials wording in Settings. Do not replace
   historical docs evidence/p2 or evidence/web-lookup images: restore baseline
   copies, and keep new renders in evidence/games and current test goldens.

After corrections: focused new regression checks, analyze/format, full suite
once, regenerate affected goldens, rebuild0.4.0+5APK, replace the not-yet-accepted
0.4.0APK/checksum, install the final APK and a short launch/Settings-return smoke.
Preserve library and no dummy keys. Update REPORT-GAMES.md/README exact evidence
and SHA; source packaging remains root-owned. No live provider key is available.

## Re-review: narrow credential-race correction

The consolidated correction passed392tests and rebuilt/installed successfully.
Main findings are resolved. Additional work is justified by a concrete auth race:
IgdbClient._post checks freshness before awaiting the new admission gate, then
sends an old token if credentials were removed while waiting. Repeat the freshness
check inside the admitted callback directly before transport.send. Also check
GamesLookupService generation immediately after storage awaits before ScanDex
send or accepting a partial. Credential-change aborts must not be classified as
quota cooldown: MetadataService now has the IGDB limiter and otherwise applies
its default60second penalty, preventing the required immediate retry.

Requested bounded regressions for queued-send cancellation, delayed key read,
and immediate retry through MetadataService, plus a bounds check before converting
an untrusted Unix timestamp to DateTime. Relevant verification and rebuilt APK
only; this is not a new feature phase. Main UI flow, schema, token sanitation,
storage failure reporting, cache generation and existing392-test evidence remain
accepted subject to those precise corrections. Source packaging remains pending.
