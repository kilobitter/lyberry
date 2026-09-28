# Sample EAN feasibility check

2026-09-24, Astra. These are read-only public web searches and ordinary direct
HTTP GET checks using the user's four samples. They are not Tavily or DeepSeek
API tests and do not establish those APIs' live coverage.

| Input | Page-supported item | Source |
| --- | --- | --- |
| 5051888100639 | Matrix, Blu-ray | [bol](https://www.bol.com/nl/nl/p/matrix/1002004013068310/), [iMusic](https://imusic.uk/movies/5051888100639/movie-2008-matrix-blu-ray) |
| 5051891186415 | Matrix 4 Film Collection, 4 Blu-rays + 4 UHD Blu-rays | [IBS](https://www.ibs.it/matrix-4-film-collection-4-film-generic-directors/e/5051891186415) |
| 045496367619 | Wii Sports Resort, Nintendo Wii; equivalent EAN 0045496367619 | [Reway](https://www.reway.nl/products/wii-sports-resort-wii), [Gameshop Twente](https://gameshop-twente.nl/wii-sports-resort-excl-motionplus-wii-gebruikt.html) |
| 5051888125168 | Argo, Blu-ray | [bol](https://www.bol.com/nl/nl/p/argo/1002004013218232/) |

Every selected page associates the barcode with the item in its product data.
No item was added to the user's library during this check.

## Direct retrieval evidence

A single ordinary unauthenticated Python urllib request was made to each URL
below, with a 12-second timeout and 1 MiB cap. No access-control bypass or retry was used.

| Page | Result | Structured data |
| --- | --- | --- |
| iMusic Matrix | HTTP 200, 377,214 bytes | Product name Matrix, gtin13=5051888100639 |
| IBS Matrix collection | HTTP 429 | Not retrieved |
| Reway Wii Sports Resort | HTTP 200, 423,282 bytes | Product name Wii Sports Resort, gtin=0045496367619 |
| bol Argo | HTTP 403 | Not retrieved |

The two successful pages are larger than the initial 256 KiB page budget.
The implementation contract was refined to 1 MiB maximum decoded page body; LLM
evidence remains capped at 12 KiB per source, 36 KiB total. Direct fetch failures make
Tavily's retrieved page content/Extract fallback useful; live Tavily success for
these pages has not been tested.

## Data quality findings

- Prefer the canonical EAN for the 12-digit UPC in web search; more listings use
  the zero-padded 13-digit form. Both forms remain equivalent for matching.
- Film production years and physical release years can differ. Preserve what a
  source actually says and expose it for editing instead of guessing.
- A [Rarewaves Matrix collection page](https://www.rarewaves.com/products/5051891186415-matrix-4-film-collection-4-4k-ultra-hd4-blu-ray-italian-import)
  pairs the correct code/title with an unrelated 5 Seconds of Summer description
  and inconsistent disc count. This illustrates why literal presence alone does
  not guarantee valid metadata; conflicting optional fields should be omitted
  and the user must review the result/source.
- Secondhand game listings can group several regional or packaging variants.
  Matching a code does not establish whether an accessory is included.

No retailer prose was copied into app fixtures by this check. Only factual
identifiers, product names and retrieval outcomes are recorded here.
