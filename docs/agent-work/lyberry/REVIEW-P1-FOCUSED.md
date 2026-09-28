# P1 focused follow-up — concrete image safety risk
Second correction cycle is justified by a material unresolved untrusted-image allocation issue, not a routine repeat review.

## Blocker
In ImageInspector._readPngHeader the scan silently stops at 64 chunks, or at IDAT, and treats the image as static; inspect still calls img.decodeImage(bytes) without a frame argument. The installed image 4.5.4 PngDecoder.decode loops over all frames when animated. A valid acTL after many ancillary chunks bypasses the guard. Also the package's startDecode processes later IHDR chunks and can use dimensions different from the initial header; WebP VP8X versus actual VP8 dimensions is a related consistency boundary. The current post-decode mismatch check comes after raster allocation.

Fix with a bounded, fail-closed metadata stage, inspect the SAME decoder's authoritative dimensions/frame count before pixel decoding, reject animated/mismatched/incomplete headers, and explicitly decode a single frame. Do not rely only on a homegrown first-header parser. If a fixed chunk budget is exhausted, reject rather than assume static. Use safe small fixtures: >64 ancillary chunks followed by animation control, conflicting duplicate IHDR / contradictory WebP canvas versus image headers. Confirm no raster decode occurs before rejection. No enormous allocation test needed. Preserve valid JPEG/PNG/WebP.

## One correction regression
RatingInput now has 5*48 +6 +48(clear) =294 logical pixels before value text. Editor content is280 on a320px phone. The rated (nonnull) narrow editor can overflow although the existing narrow test only covers null rating. Adapt the rating row to wrap or put value/clear below at narrow widths while retaining accessible controls. Add narrow+nonnull+large-text widget regression.

Run targeted image and rating tests, analyzer and final suite; update report and only affected render(s). Then complete the handoff. All other review groups are accepted; don't rework unrelated code. No P2 features yet.

