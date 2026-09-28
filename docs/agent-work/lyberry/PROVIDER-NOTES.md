# Provider limits for P2

Verified UPCitemdb official free plan documentation 2026-09-23: no registration/key, 100 combined requests/day, 6 lookups/minute, sustainable one request every 10 seconds, primarily IP-based. Implement per-provider 10s spacing without blocking the UI or other providers, cancellation where appropriate, and useful quota/cooldown status. Observe Retry-After/reset headers conservatively; do not auto-retry. Cache completed lookups to avoid repeat consumption.

Sources: https://www.upcitemdb.com/wp/docs/main/development/plan/ and https://www.upcitemdb.com/wp/docs/main/development/api-rate-limits/ . The pages disagree on search daily sublimits; Lyberry v1 only uses lookup, so do not rely on either search quota.
