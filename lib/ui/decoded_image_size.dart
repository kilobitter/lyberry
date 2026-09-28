import 'package:flutter/widgets.dart';

/// Pixel width that decodes a stored image at roughly its display size.
///
/// Grid tiles and thumbnails must not hold full-resolution rasters in memory.
int decodedImageWidth(BuildContext context, double logicalWidth) =>
    (logicalWidth * MediaQuery.devicePixelRatioOf(context)).round();
