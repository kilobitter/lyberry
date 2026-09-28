import 'package:lyberry/domain/validation.dart';

/// A crop rectangle plus the quarter turns applied before cropping.
///
/// [left], [top], [width] and [height] are normalized to the orientation
/// corrected, quarter turned image, so the same rectangle means the same slice
/// of the photo no matter what size the preview or the saved cover ends up.
/// [quarterTurns] counts clockwise quarter turns (0-3) applied after the EXIF
/// orientation has been baked, matching what the preview shows.
class CoverCrop {
  const CoverCrop({
    this.left = 0,
    this.top = 0,
    this.width = 1,
    this.height = 1,
    this.quarterTurns = 0,
  });

  /// The whole oriented image with no extra rotation.
  static const CoverCrop full = CoverCrop();

  final double left;
  final double top;
  final double width;
  final double height;
  final int quarterTurns;

  /// Tolerance for the floating point arithmetic that moves the crop handles.
  static const double _epsilon = 1e-6;

  bool get isFull =>
      quarterTurns == 0 &&
      left.abs() <= _epsilon &&
      top.abs() <= _epsilon &&
      (width - 1).abs() <= _epsilon &&
      (height - 1).abs() <= _epsilon;

  CoverCrop copyWith({
    double? left,
    double? top,
    double? width,
    double? height,
    int? quarterTurns,
  }) {
    return CoverCrop(
      left: left ?? this.left,
      top: top ?? this.top,
      width: width ?? this.width,
      height: height ?? this.height,
      quarterTurns: quarterTurns ?? this.quarterTurns,
    );
  }

  /// Every reason this rectangle cannot be rendered, in a stable order.
  ///
  /// Empty, non-finite and out-of-bounds rectangles are rejected here, before
  /// any decode work starts, so a bad drag can never reach the encoder.
  List<ValidationIssue> validate({String field = 'cover'}) {
    final issues = <ValidationIssue>[];
    if (!_isFinite(left) ||
        !_isFinite(top) ||
        !_isFinite(width) ||
        !_isFinite(height)) {
      issues.add(
        const ValidationIssue('cover', 'The crop area is not a valid region.'),
      );
      return issues;
    }
    if (width <= 0 || height <= 0) {
      issues.add(
        const ValidationIssue(
          'cover',
          'Choose at least a sliver of the photo.',
        ),
      );
    }
    if (left < -_epsilon ||
        top < -_epsilon ||
        left + width > 1 + _epsilon ||
        top + height > 1 + _epsilon) {
      issues.add(
        const ValidationIssue(
          'cover',
          'The crop area must stay inside the photo.',
        ),
      );
    }
    if (quarterTurns < 0 || quarterTurns > 3) {
      issues.add(
        const ValidationIssue('cover', 'That rotation is not supported.'),
      );
    }
    return issues;
  }

  void assertValid({String field = 'cover'}) {
    final issues = validate(field: field);
    if (issues.isNotEmpty) throw ValidationException(issues);
  }

  /// The rectangle clamped into the image and rounded to whole pixels.
  ///
  /// Used by the renderer so a rectangle that is a floating point hair outside
  /// the image still produces a real, non-empty slice.
  ({int x, int y, int width, int height}) toPixels({
    required int imageWidth,
    required int imageHeight,
  }) {
    var x = (left * imageWidth).round();
    var y = (top * imageHeight).round();
    var pixelWidth = (width * imageWidth).round();
    var pixelHeight = (height * imageHeight).round();
    x = x.clamp(0, imageWidth - 1);
    y = y.clamp(0, imageHeight - 1);
    pixelWidth = pixelWidth.clamp(1, imageWidth - x);
    pixelHeight = pixelHeight.clamp(1, imageHeight - y);
    return (x: x, y: y, width: pixelWidth, height: pixelHeight);
  }

  static bool _isFinite(double value) => value.isFinite;

  @override
  bool operator ==(Object other) =>
      other is CoverCrop &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height &&
      other.quarterTurns == quarterTurns;

  @override
  int get hashCode => Object.hash(left, top, width, height, quarterTurns);

  @override
  String toString() =>
      'CoverCrop($left, $top, $width, $height, turns: $quarterTurns)';
}
