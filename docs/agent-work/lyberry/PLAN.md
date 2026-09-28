# Dependency plan
P1 — Local collection vertical slice. ACCEPTED: stable models+SQLite repository, styled home/detail/editor, all media filters/search, ratings/reviews/notes, multiple copies, local photo support. 87 tests pass; analyzer/format clean. See ACCEPTANCE-P1.md. Native build is pending P2.
P2 — Scanning, metadata and portable backup. ACCEPTED after actual-code review, one consolidated correction and a focused storage trust/resource-bound follow-up. 196 tests, analyzer and format pass; Android debug APK built. See ACCEPTANCE-P2.md for precise evidence and platform/live-provider limits.
P3 — Final acceptance and handoff. COMPLETE: project/source archive, actual Android debug APK, README and rendered evidence delivered. Native camera/gallery/file-dialog verification requires a usable device; iOS build requires full Xcode; Open Library live verification was DNS-blocked. No publication/signing/Git operations performed.

No Git repository at baseline; compare file inventory/hash snapshots. Do not initialize/commit Git automatically. Root owns docs/agent-work/lyberry/{DESIGN,PLAN,CHECKPOINT,BRIEF-*}.md; worker owns all other in-project files and unique reports/evidence.
