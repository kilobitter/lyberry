# Astra acceptance — Lyberry 0.3.0

Accepted 2026-09-25 for the Android debug/source handoff. The interrupted web
lookup feature is implemented and reviewed against the captured 0.2.0 baseline.
Astra owned architecture, review and acceptance; the same native Flash worker
implemented, debugged, tested and built it. Routing evidence is in CHECKPOINT.md.

Free catalogues remain automatic. An explicit action uses Tavily search or a
pasted URL, matching structured product data first, and optional DeepSeek extraction
from retrieved evidence. Own keys are stored in the device keystore/keychain.
Candidates require user selection and normal editor save. No library or backup
schema migration was introduced.

## Review and verification

- Reviewed modified and new source/configuration against the169-file baseline.
  Corrections covered cancellation/single-flight, deadlines, transmitted evidence,
  public-address checks, storage errors and narrow layouts. Focused fixes addressed
  cancel/retry/dispose identity and empty transmitted evidence.
- Root's real-page probe exposed missing TLS in the custom pinned socket. The
  amended design and code upgrade validated TCP using SecureSocket.secure with
  the original hostname and platform trust. Production supplies no bypass hook.
- Final saved evidence: **311 tests passed**, analyzer clean, formatting clean
  (113 Dart files). Includes real socket/TLS tests, secure-store platform mocks,
  cancellation races, JSON/evidence validation and UI renders. Root inspected
  final source and evidence without rerunning the full suite.
- TLS-test limit: successful local synthetic-certificate tests use a test-only
  certificate hook because the attempted synthetic trust context failed on this
  Dart build. Strict-path tests reject the untrusted certificate. A host observer
  verifies the hostname passed to TLS; the hook-based mismatch test does not
  independently prove platform hostname verification. Production uses the standard
  verifier, and two real HTTPS fetches succeeded without an injected hook.
- Production fetch/extraction: iMusic HTTP200, Matrix/5051888100639; Reway HTTP200,
  Wii Sports Resort/0045496367619, equivalent to scanned UPC045496367619. Both use
  structured metadata without keys. See live-web-page-probe.log.
- Fresh Gradle (`--no-daemon --no-watch-fs`, JBR21) built Android0.3.0/code3. Root
  independently verified APK SHA256 and version metadata.
- Pixel8a API37: install preserving collection; dummy Tavily key save, replacement,
  restart persistence, removal and removal persistence; missing-key setup/manual
  fallback. No fatal/ANR reported, dummy key removed, airplane mode restored and
  existing test collection preserved. Device screenshots inspected.

APK: deliverables/lyberry-0.3.0-debug.apk
SHA256: e948f4db3d61beb6cfdfacdd1a4f6c20ab8887daa38a98823f8042730b53c47b

## Limits and packaging

No live Tavily/DeepSeek request used a real key. Their API contracts and extraction
failures are fixture-tested; end-to-end paid-provider accuracy still requires the
user's keys entered in Settings. Retailer access/contents vary; suggestions need
review. iOS runtime needs full Xcode. Camera decoding, gallery selection and native
file dialogs retain their prior unverified device status. No release signing,
publication, Git commit or deployment was performed.

Source packaging includes native configuration (including Runner.entitlements),
source/tests/docs. Generated caches, local SDK paths, device databases and APKs are
excluded. The original 0.2.0 APK and source archive hashes remain unchanged.
