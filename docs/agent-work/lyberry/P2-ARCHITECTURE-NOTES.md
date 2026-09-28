# P2 implementation refinements

## Photo reads on Android
Android SQLite cursors have bounded CursorWindow storage, and sqflite_android uses the ordinary rawQueryWithFactory cursor path. A single allowed5MiB asset row may exceed that window even though desktop FFI tests pass. Preserve the existing atomic SQLite BLOB architecture and schema, but read asset metadata without the data column, then retrieve data via bounded SQLite substr(data, offset, length) slices (e.g.256KiB, 1-based offsets), validating stored length and reconstructing the immutable asset. Never SELECT * / whole multi-MiB data into an Android cursor. Reuse the safe reader for export. No schema migration or filesystem-photo redesign is needed. Add a >2MiB valid-image roundtrip test and Android integration evidence if a device/emulator is available.

Primary evidence: https://developer.android.com/reference/android/database/CursorWindow.html documents the finite cursor-window allocation. Installed sqflite_android-2.4.2+3 Database.java uses rawQueryWithFactory. This is an Astra architecture adjustment for mobile compatibility before final handoff, not a request to redesign storage.

## Cover transport
Prefer a conservative allowlist for image downloads to a general-purpose URL client. Initial hosts may include covers.openlibrary.org, coverartarchive.org, archive.org and its proper dot-subdomains (for Cover Art Archive redirects), m.media-amazon.com, images-na.ssl-images-amazon.com, i.ebayimg.com and i5.walmartimages.com. Other hosts can fail gracefully to the medium placeholder. Only HTTPS443, no userinfo/IP-literal/private/loopback host, strict byte/time limits, at most3 redirects, validate every redirect before following. If resolving hosts, reject private/link-local/loopback addresses. Never auto-download anything from imported source URLs; backups already contain image bytes.

## Image validation
P1 focused review must be complete before P2. Keep expensive image parsing/backup validation off the UI isolate where possible. Avoid validating every unchanged cached image repeatedly while scrolling.
