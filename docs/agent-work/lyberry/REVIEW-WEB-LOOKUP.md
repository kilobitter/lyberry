# Astra review — web lookup

2026-09-24. Compared the 169-file pre-feature baseline and new source/configuration
with the implementation report and test evidence. Existing library/database and
backup formats are preserved; UI routes are explicit; candidates retain trusted
source provenance. The initial 277 tests/analyze/format results are verified in
their saved logs. One consolidated correction cycle is required before acceptance.

## Corrections

1. **Paid-stage cancellation and single-flight (high priority).** Both public
   service methods return `_finish(...)` inside `try/finally` without awaiting it,
   releasing `_inFlight` while extraction remains active. Controller cancellation
   uses one resettable boolean, so a new tap can reactivate a cancelled request.
   Link import calls Tavily Extract after a cancelled fetch; cancellation during
   key reads is not checked before the next request. Use per-operation immutable
   cancellation identity; await the whole pipeline before releasing its lock;
   check cancellation/deadline after every awaited prerequisite and before each
   paid stage. Test cancel/retry, cancelled link fallback, delayed key reads and
   duplicate actions during model extraction.
2. **Actual whole-pipeline deadline.** `_finish` and `_extractFallback` receive no
   deadline; DeepSeek defaults to 60 seconds instead of the contracted 30-second
   API cap. Clamp every stage to remaining budget, distinguish timeout from user
   cancellation, and stop before starting the next stage. Tavily Extract also
   needs the contracted `timeout: 10` request field. Test an exhausted nonzero
   budget with delayed stages, not only a zero initial budget.
3. **Validate precisely the evidence sent.** DeepSeek truncates a concatenated
   block by character count but validates against the original untruncated pages;
   quote/source metadata can be beyond the transmitted evidence. Construct bounded
   UTF-8 evidence once and validate that exact source map, retaining whole source
   boundaries/code context. Handle spaces/hyphens in equivalent identifiers in both
   evidence gating and quote validation. Reject non-stop/truncated completions
   (finish_reason is currently ignored). Add multilingual byte-budget, omitted
   evidence, separator and length/content_filter completion regressions.
4. **Public IPv6 policy.** The default `true` branch permits non-global addresses
   such as `fec0::1` and reserved prefixes. Enforce a conservative globally routable
   policy with explicit special-purpose exclusions and regression cases. DNS
   timeout occurs outside `_singleRequest`'s exception mapping; return the same
   sanitized timeout failure. Cancellation should abort a stalled page request,
   not require its next response-body chunk.
5. **Secure storage verification.** Production `has()` hides read errors as
   Not configured; `write()` accepts any nonempty read-back, including a stale old
   value after a failed replacement. Surface read failure in Settings and compare
   read-back to the intended key. Current store tests exercise only the fake store;
   test `SecureApiKeyStore` through mocked plugin/platform storage, including stale
   write-back and read/delete exceptions. Never expose secret values in diagnostics.
6. **Narrow result layout.** Candidate badge and action Rows have inflexible
   content. Add result and Settings coverage at 320x568 / 1.6 text scale and wrap
   where needed; inspect the resulting renders. Existing narrow renders cover
   link/empty only.
7. **Production transport tests.** Provider tests use FakeApiTransport; add local
   socket tests of IoApiTransport for no redirect/credential forwarding, total
   deadline, body cap and sanitized network errors. No real keys or paid calls.
8. **Accurate build diagnosis.** Silent exit plus daemon EOF does not establish
   that the sandbox kills a Flutter helper. Older successful build logs also
   contain EOF. Report it as unexplained until a concrete cause is demonstrated;
   root is investigating narrowly scoped toolchain-cache permissions. Do not use
   an unsandboxed terminal/GUI as a workaround for a denied permission.

## Remaining acceptance

Review the corrected patch and regression evidence, build Android 0.3.0, exercise
synthetic key lifecycle on the emulator if accessible, and package source with
Runner.entitlements (a required build input). Live paid-provider and iOS runtime
validation remain explicitly outside verified coverage.

## Focused follow-up findings

The consolidated corrections passed 304 tests. Two concrete residual issues need
focused verification: cancel/retry/dispose can overwrite `_cancelledGeneration`
and reactivate an older operation; and an empty transmitted evidence map must
prevent a model request. These were returned to the same Flash worker.

An independent root run of production SafePageFetcher/ProductExtractor against
the supplied Matrix/iMusic and Wii Sports Resort/Reway pages returned HTTP400 for
both. SDK source inspection established that a supplied HttpClient.connectionFactory
replaces TLS establishment too. Returning Socket.startConnect alone sent plaintext
on443. The original architecture note incorrectly assumed automatic TLS wrapping.
The amended contract requires a pinned TCP connection explicitly upgraded through
SecureSocket.secure with the original hostname and normal certificate verification,
then exposed via a cancellable ConnectionTask. A real local TLS regression and
repeat key-free public-page probe are required before rebuilding the final APK.
This extra correction is justified by concrete security/functional evidence.
