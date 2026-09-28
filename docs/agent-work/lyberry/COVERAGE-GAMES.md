# ScanDex public coverage check

2026-09-25, Astra acceptance context. Used the public lookup form at
https://scandex.gamery.app/ in the Codex in-app browser. Entered the user's
UPC `045496367619` and clicked Lookup. The visible result was **No results found.**
The input retained the same UPC. This is a public UI observation, not a request
to the authenticated ScanDex API and not evidence about IGDB title-search results.

The user previously identified this copy as Wii Sports Resort for Nintendo Wii.
The game title search remains necessary even with ScanDex integration. Synthetic
ScanDex/IGDB fixture success for this code tests parsing/routing only and must
not be described as proof of live barcode coverage.
