import 'package:flutter/material.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/media_cover.dart';
import 'package:lyberry/ui/widgets/star_rating.dart';

/// One collection grid cell: cover, title, byline and rating.
class CoverTile extends StatelessWidget {
  const CoverTile({
    super.key,
    required this.item,
    required this.image,
    required this.onTap,
    this.cacheWidth,
  });

  final MediaItem item;
  final Future<MediaAsset?>? image;
  final VoidCallback onTap;
  final int? cacheWidth;

  /// Vertical space the caption needs at the current text scale.
  static const double captionHeight = 94;

  /// Square cover plus the scaled caption; keeps the grid free of overflow.
  static double extentFor(BuildContext context, double crossAxisExtent) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return crossAxisExtent + captionHeight * scale;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${item.title}, ${item.byline}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LyberryMetrics.corner),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 1,
              child: MediaCover(
                medium: item.medium,
                image: image,
                cacheWidth: cacheWidth,
                semanticLabel: '${item.title} cover',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: LyberryColors.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              item.byline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.3,
                color: LyberryColors.muted,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 20,
              child: Align(
                alignment: Alignment.centerLeft,
                child: StarRating(rating: item.rating, iconSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
