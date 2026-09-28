# P1 accepted

Astra accepts the local collection slice after the actual-code specification and quality review, one consolidated correction, and a focused second correction justified by untrusted-image memory allocation risk. Review included the authored source, changed safety/rating code, real SQLite tests, report/logs, and rendered phone/narrow-layout evidence. No duplicate full-suite run was needed.

Evidence: 87 passing tests (36 domain, 9 service, 17 SQLite, 20 widget, 5 rendering); analyzer clean; 50 Dart files formatted with zero changes. The focused fix checks the selected decoder's metadata before pixel allocation and explicitly decodes one frame; the narrow rated editor now wraps its controls. Android compile and physical hardware checks remain pending P2. This accepts the phase, not the full app.

P2 must finish all deferred import validation, bounded asset cache, Android chunked BLOB reads, scanner/metadata services, native backup UI, final README and build evidence. See BRIEF-P2.md and P2-ARCHITECTURE-NOTES.md. Baseline authored files and hashes are saved outside deliverables at work/baselines/p1-accepted; no Git operations were performed.
