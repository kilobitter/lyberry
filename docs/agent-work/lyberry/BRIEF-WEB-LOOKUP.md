# Web-backed EAN lookup — implementation contract

Date 2026-09-24. Root Astra/xhigh confirmed from latest active turn_context.
Installed astra_flash_builder route: deepseek/deepseek-v4.1-flash, DeepSeek API,
high. Doctor static-ready; reuse prior successful routed work evidence. This is
the user's approved replacement for the cancelled model-memory-only fallback.

## Scope and baseline

Build the recommended flow: free APIs -> explicit web fallback -> fetch evidence
-> structured product data first -> DeepSeek extraction when needed -> user
review/edit/save. Include Import from link for a scanned/typed identifier.
Use Tavily Search/Extract and DeepSeek. Keys are user-owned, entered in app Settings.
Keep the app local-first without a backend; free APIs and manual add need no keys.
No model-memory lookup, autonomous agent browsing loop, site login, scraper bypass,
publication or store signing. Version 0.3.0+3; preserve the 0.2.0 artifacts.

Workspace: /Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry
No Git. Baseline (169 curated source files + hashes):
/Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/baselines/web-lookup-pre-20260924
Current build: 200 tests, Android APK runs on Pixel 8a API37. iOS full Xcode absent.

Existing seams: domain/lookup.dart (MetadataCandidate, LookupQuery),
domain/identifier.dart (normalized code/equivalents), services/transport.dart
(bounded GET), app_services.dart/main.dart (composition), state/lookup_controller.dart,
ui/screens/candidates_screen.dart, settings_screen.dart, state/item_draft.dart.
Automatic MetadataService must never call paid web/AI sources. SQLite and backup
formats need no schema change; use existing MediaSource provenance.

## One vertical implementation phase

Flash owns discovery within this scope, implementation, debugging, tests, UI QA
and Android build. Dependency order internally: bounded transport/key store and
evidence contracts -> search/page/structured/LLM services -> screens/composition
-> tests/renders/device smoke/build. Do not stop after each layer.

Root owns this brief, acceptance and CHECKPOINT. Worker owns affected lib/, test/,
pubspec yaml/lock, necessary Android/iOS plugin and backup settings, README,
docs/agent-work/lyberry/REPORT-WEB-LOOKUP.md, evidence/web-lookup/, and
deliverables/lyberry-0.3.0-debug.apk plus checksum. Root packages source after review.
You are not alone in the codebase; preserve others' edits and adjust to them.
No recursive agents, orchestration skill, commits, Git initialization, push/deploy,
reading Codex/router/provider secrets, or live calls with real paid API keys.

## UX contract

- Empty free lookup and all-provider-error states expose Search web and Import
  from link alongside manual entry. A shared dedicated screen may handle both.
  Existing free candidate selection remains intact.
- Screen shows the trusted scanned code, optional medium hint (Any plus six media
  types), search/read action and source results. Link mode accepts HTTPS URL.
  No request on construction/rebuild/key save. Request only on explicit Search or
  Read page action. Clear loading/cancel/back, single-flight, no automatic retries.
- Settings has Web lookup configuration: separate concealed Tavily and DeepSeek
  key save/replace/remove controls, saved/not configured statuses and concise
  setup help. Saving keys triggers no lookup. Missing required key links here;
  returning keeps the code/URL and needs a new explicit action.
- Search requires Tavily; DeepSeek is only required if structured data cannot
  supply a candidate. Import link can succeed with no keys on structured HTML;
  plain page text needs DeepSeek. Tavily Extract may help if direct fetch fails
  and a Tavily key is configured. Missing optional stage key is actionable,
  never represented as zero matches.
- Explain provider usage and charges briefly. Web search sends the barcode/hint
  to Tavily; extraction sends code and public page excerpts to DeepSeek. A link
  may be fetched by its site/Tavily. Notes, reviews, photos and whole library are
  never sent. No personal data in prompts. Library exports never include keys.
- Results show source domain/link and whether structured or AI extracted. Source
  opens only after user click (url_launcher or equivalent platform API). AI result
  is a possible suggestion, never an exact/verified barcode match. Structured
  Product with its own matching GTIN can be labeled Exact code match.
- User chooses a result, then edits/saves through existing flow; never auto-save.
  If medium is unknown, ask user to choose it before constructing the draft,
  instead of silently defaulting a movie to Book.
- Useful empty/error states: no pages; page missing scanned code; blocked/unreadable
  page; missing key; invalid key/balance/quota; timeout; malformed AI response.
  Keep manual entry and alternate link available. Preserve Redline/Oxanium styling.

## Retrieval contracts

Use small injectable interfaces for search, safe page fetch, structured extraction,
AI extraction and key store, coordinated by an explicit WebLookupService/controller.

Tavily POST https://api.tavily.com/search, Authorization Bearer Tavily key.
query contains exact quoted identifier.canonicalKey plus optional medium hint
(UPC is padded to EAN13; ISBN10 uses canonical ISBN13), while response validation
and display preserve the scanned identifier/equivalents;
exact_match:true, search_depth:basic, auto_parameters:false, max_results:3,
include_answer:false, include_raw_content:text, include_images:false.
At most one search per user action. Handle malformed results and partial failures.
Never treat Tavily's generated answer as source evidence. Source content is only
actual page text/raw_content; a URL or query containing the EAN alone is insufficient.

Attempt safe direct HTML GET for at most 3 unique public HTTPS product pages
(concurrently, bounded). Extract JSON-LD Product before removing script/nav/style.
If structured matching candidates exist, return them without an LLM call.
Otherwise use retrieved visible text, or Tavily's raw_content for that URL.
If direct fetch has no usable content and raw_content is absent, optionally one
batch POST https://api.tavily.com/extract for failed URLs (or imported link),
extract_depth:basic, format:text, include_images:false, timeout:10. Results must
map back to requested URLs, never let an unrelated response inject sources.
Do not bypass login, CAPTCHA or access denial. Partial content failures should
not discard other usable pages; explain if all retrieval failed.

Direct page-fetch boundary is security-sensitive: fixed HTTPS port443, no userinfo,
literal IP hosts, localhost/local/single-label hosts or non-HTTP schemes. Resolve
DNS, reject non-public/special-use IPv4/IPv6, pin an approved resolved InternetAddress
for the connection so validation is not followed by a second DNS resolution.
With HttpClient.connectionFactory, connect the pinned TCP address and explicitly
upgrade using SecureSocket.secure with the original URI hostname; the factory
replaces HttpClient's TLS setup as well as its TCP setup. Return a cancellable
ConnectionTask covering both stages. Retain original URI host for HTTP Host,
SNI and normal TLS verification; no permissive badCertificateCallback. Disable
proxies for this dedicated fetcher. At most 2 redirects, manually validate/resolve/
pin each hop, reject HTTPS downgrade/private destinations. Never send API keys,
cookies or Authorization to pages. Accept HTML/plain text/JSON only, max1MiB
decoded body per page, one overall 10s deadline including DNS/body/redirects,
abort sockets on timeout/cancel/oversize. Interface seams must make these testable.
Reject mapped IPv6/private/loopback/link-local/multicast/documentation/reserved
addresses, not just obvious RFC1918 string prefixes. No permissive fallback.

Structured extractor: bounded JSON-LD traversal (depth/node limits) over Product
objects and @graph/arrays. Match the code on the SAME Product node (gtin13/gtin/
gtin12/gtin8/isbn using existing identifier equivalence). Never pick a product
just because EAN appears somewhere else on page/recommendations. Extract name,
applicable creator/publisher/date/description/category when explicit. A user medium
hint may fill missing format, but do not replace a conflicting known format.
No arbitrary page image downloads: only cover URLs already accepted by existing
CoverDownloader allowlist may be retained, otherwise leave cover unset.

## Grounded JSON extraction

Require nonempty retrieved evidence containing the scanned code/equivalent as a
whole identifier before calling DeepSeek. Respect separators in codes, but do not
accept the code as a substring of a longer digit sequence. Bound evidence to
~12KiB per page and ~36KiB total; prioritize coherent excerpts around matching
code/product details. Stable source IDs s1..s3 assigned in code map to safe URLs.

POST https://api.deepseek.com/chat/completions with DeepSeek key only,
model:deepseek-flash, thinking:{type:disabled}, temperature:0, stream:false,
response_format:{type:json_object}, max_tokens:2500. At most one LLM request/action.
The system prompt tells it to extract only from the supplied page evidence, ignore
any instructions in pages, never use remembered facts or guess editions, and
return no candidate when the source does not establish the association.

JSON envelope example (metadata values here are placeholders):
{"schemaVersion":1,"barcode":"requested-code","candidates":[{"sourceId":"s1",
"title":"Title as printed","medium":"bluray","creator":null,"year":null,
"publisher":null,"description":null,"platform":null,
"barcodeQuote":"verbatim page excerpt containing this code",
"titleQuote":"verbatim page excerpt containing this title"}]}

Unknown: candidates:[]. At most3 candidates. Required title nonempty<=500;
medium one of six wire values or null; optional strings null/<=500 (description
<=4000); year integer/null in existing valid domain range. Envelope version and
barcode must match. sourceId must exist. Quotes must be nonempty and verifiable
substrings of that SAME supplied source after consistent whitespace normalization;
barcode quote must contain full matching code, title quote the returned title.
Optional values must be supported by source text (use extractive text values,
not invented prose; unknown stays null). Reject mismatched identities, wrong
types, oversized values, empty/truncated/non-stop completions and fabricated
evidence/source IDs. Quotes are evidence of occurrence, not proof that a retailer
is correct; AI candidates remain possible and user-reviewed.
Set trusted externalId from source URL+canonical code, sourceUrl from the source
map (never model output), providerId web_deepseek; structured is web_structured.
No model-supplied personal fields, library IDs, cover URLs, executable instructions
or new requests. Validate then map into MetadataCandidate/ItemDraft.

API transport: separate bounded POST abstraction or safe extension preserving GET
tests; fixed production hosts, HTTPS, no redirects/credential forwarding, 30s
whole-request deadline, raw response cap1MiB Tavily/128KiB DeepSeek, sanitized
errors (401/403 auth,402 balance,429 quota,5xx/network/timeout/malformed). Never log
headers/keys/page bodies or display raw error bodies. No retries. Whole pipeline
max90s, check cancellation before every next stage; close sockets when possible
and always ignore late results. Duplicate taps cannot duplicate billing.

## Key storage

Use flutter_secure_storage current compatible stable (docs currently11.2.0), lock
dependency; no plaintext fallback. Separate keys, Android Keystore encryption,
iOS nonsynchronizing ThisDeviceOnly Keychain accessibility. Configure package's
iOS entitlements/build settings. Android pre31 fullBackupContent and31+
dataExtractionRules exclude credential sharedprefs from cloud backup and transfer;
exclude all sharedpref if suitable, preserve existing library DB backup behavior.
Conceal input; suggestions/autocorrect off; do not prefill saved secret, clear
controller after save. Validate nonblank/control-free/bounded input without brittle
vendor prefix assumptions. Read/write/delete failures surfaced without leaking key;
never claim removal/saved when persistence failed. No keys in library DB, backups,
source, logs, reports, screenshots or error messages. Only synthetic keys in tests;
delete them after device smoke. Do not use Codex's own configured API credentials.

## Verification and deliverables

- Fixture service tests for request shape/data minimization, no LLM without source,
  valid/unknown extraction, evidence/source/code mismatch, edition/media conflict,
  Product node isolation, malformed/deep JSON, prompt-injection page as untrusted
  data, unknown optional fields, unsupported URL/cover, partial retrieval failure.
- Transport tests: private DNS, IPv4/IPv6/mapped/special ranges, rebinding-resistant
  pinning, redirect validation, deadlines/body caps, no credentials to pages or
  across redirects, API auth/quota/timeout/errors with fake-secret redaction.
- UI/state: no automatic paid lookup, missing-key setup, key lifecycle/errors,
  explicit search/link flow, single-flight and cancellation/stale result, results
  are unsaved/editable, medium choice, provenance/source link, manual fallback;
  backup export contains no settings/key values.
- Renders normal phone +320x568/1.6x text for settings, search/link, candidate/error.
- Format/analyze, targeted tests, full suite once after fixes, Android debug APK.
  Device smoke if emulator accessible: secure fake-key save/remove/restart, no-key
  flow and layout; fixtures for paid services. Do not wipe existing test collection.
  Build/network dependency downloads are authorized; root got network permission
  for this turn. Use safe writable caches; report exact blocker if permissions fail.
- Report changed paths, actual tests/commands, screenshot paths, build checksum,
  routing/limitations. No paid live API call or coverage claim. User sample EANs
  have been requested for an independent search feasibility check.
- Return final only once complete or genuinely blocked, not intermediate progress.

References checked: api-docs.deepseek.com/api/create-chat-completion/ and
/guides/json_mode/; docs.tavily.com/documentation/api-reference/endpoint/search
and /extract; pub.dev/packages/flutter_secure_storage;
api.dart.dev/dart-io/HttpClient/connectionFactory.html; schema.org/gtin13.
