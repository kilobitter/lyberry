import 'dart:convert';

import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/cover_downloader.dart';

/// One schema.org `Product` node whose own GTIN matched the requested code.
class StructuredProduct {
  const StructuredProduct({
    required this.title,
    required this.matchedCode,
    this.medium,
    this.creator = '',
    this.publisher = '',
    this.year,
    this.description = '',
    this.platform = '',
    this.coverUrl,
  });

  final String title;

  /// The form of the code written on that same Product node.
  final String matchedCode;
  final MediaType? medium;
  final String creator;
  final String publisher;
  final int? year;
  final String description;
  final String platform;
  final String? coverUrl;
}

class ProductExtraction {
  ProductExtraction({
    List<StructuredProduct> products = const <StructuredProduct>[],
    required String visibleText,
  }) : products = List<StructuredProduct>.unmodifiable(products),
       visibleText = visibleText.trim();

  final List<StructuredProduct> products;
  final String visibleText;
}

/// Bounded JSON-LD `Product` extraction plus visible-text recovery.
///
/// The extractor never guesses: a product counts only when the requested code
/// appears on that same node's own GTIN fields, so a recommendation rail or a
/// review mentioning the barcode elsewhere on the page cannot become a match.
abstract final class ProductExtractor {
  static const int maxScripts = 60;
  static const int maxJsonBytes = 512 * 1024;
  static const int maxJsonDepth = 12;
  static const int maxNodes = 4000;
  static const int maxVisibleText = 400 * 1024;
  static const int maxFieldLength = 500;
  static const int maxDescriptionLength = 4000;

  /// Extracts matching products and visible text from one page body.
  ///
  /// [matchesCode] receives digit-only candidate codes and answers whether they
  /// are equivalent to the requested identifier.
  static ProductExtraction extract(
    String html, {
    required bool Function(String digits) matchesCode,
  }) {
    final products = <StructuredProduct>[];
    final seen = <String>{};
    var scanned = 0;
    for (final match in _jsonLdBlocks(html)) {
      if (scanned >= maxScripts) break;
      scanned++;
      final raw = match.trim();
      if (raw.isEmpty || raw.length > maxJsonBytes) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on Object {
        continue;
      }
      final budget = _NodeBudget(maxNodes);
      for (final node in _productNodes(decoded, budget)) {
        final product = _productFrom(
          node,
          matchesCode: matchesCode,
          seen: seen,
        );
        if (product != null) products.add(product);
      }
    }
    return ProductExtraction(
      products: products,
      visibleText: visibleText(html),
    );
  }

  /// Script bodies that declare JSON-LD, in page order.
  static Iterable<String> _jsonLdBlocks(String html) sync* {
    final pattern = RegExp(
      "<script[^>]*type\\s*=\\s*[\"']application/ld\\+json[^>]*>(.*?)</script>",
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in pattern.allMatches(html)) {
      yield match.group(1) ?? '';
    }
  }

  /// Every `Product`-typed node reachable inside the bounded budget.
  static Iterable<Map<String, Object?>> _productNodes(
    Object? node,
    _NodeBudget budget,
  ) sync* {
    final stack = <(Object?, int)>[(node, 0)];
    while (stack.isNotEmpty) {
      final (current, depth) = stack.removeLast();
      if (depth > maxJsonDepth) continue;
      if (!budget.spend()) return;
      if (current is List) {
        for (final entry in current) {
          stack.add((entry, depth + 1));
        }
        continue;
      }
      if (current is! Map) continue;
      final map = current.cast<String, Object?>();
      if (_isProduct(map)) yield map;
      for (final value in map.values) {
        if (value is Map || value is List) stack.add((value, depth + 1));
      }
    }
  }

  static bool _isProduct(Map<String, Object?> node) {
    for (final type in _typeNames(node['@type'])) {
      final lower = type.toLowerCase();
      if (lower == 'product' || lower.endsWith('/product')) return true;
    }
    return false;
  }

  static Iterable<String> _typeNames(Object? value) sync* {
    if (value is String) {
      yield value;
    } else if (value is List) {
      for (final entry in value) {
        if (entry is String) yield entry;
      }
    }
  }

  static StructuredProduct? _productFrom(
    Map<String, Object?> node, {
    required bool Function(String digits) matchesCode,
    required Set<String> seen,
  }) {
    final matched = _matchedGtin(node, matchesCode);
    if (matched == null) return null;
    final title = _text(node['name']);
    if (title.isEmpty) return null;
    final identity = '$matched|$title';
    if (!seen.add(identity)) return null;

    final image = _imageUrl(node);
    return StructuredProduct(
      title: _clip(title, maxFieldLength)!,
      matchedCode: matched,
      medium: _medium(node),
      creator: _clip(_brand(node), maxFieldLength) ?? '',
      publisher: _clip(_publisher(node), maxFieldLength) ?? '',
      year: _year(node),
      description: _clip(_description(node), maxDescriptionLength) ?? '',
      platform: _clip(_platform(node), maxFieldLength) ?? '',
      coverUrl: image,
    );
  }

  /// The first GTIN-ish field on this node that matches the requested code.
  static String? _matchedGtin(
    Map<String, Object?> node,
    bool Function(String digits) matchesCode,
  ) {
    const fields = <String>[
      'gtin13',
      'gtin14',
      'gtin12',
      'gtin8',
      'gtin',
      'isbn',
      'isbn13',
    ];
    for (final field in fields) {
      final value = node[field];
      for (final candidate in _stringValues(value)) {
        final digits = candidate.replaceAll(RegExp(r'[^0-9Xx]'), '');
        if (digits.isEmpty) continue;
        if (matchesCode(digits)) return digits;
      }
    }
    return null;
  }

  static Iterable<String> _stringValues(Object? value) sync* {
    if (value is String) {
      yield value;
    } else if (value is num) {
      yield value.toString();
    } else if (value is List) {
      for (final entry in value) {
        yield* _stringValues(entry);
      }
    } else if (value is Map) {
      final map = value.cast<String, Object?>();
      yield* _stringValues(map['@value']);
      yield* _stringValues(map['value']);
      yield* _stringValues(map['name']);
    }
  }

  static String _text(Object? value) => _stringValues(
    value,
  ).firstWhere((entry) => entry.trim().isNotEmpty, orElse: () => '');

  static String _brand(Map<String, Object?> node) {
    for (final field in const <String>['brand', 'author', 'creator']) {
      final value = _text(node[field]);
      if (value.trim().isNotEmpty) return value;
    }
    return '';
  }

  static String _publisher(Map<String, Object?> node) {
    for (final field in const <String>['publisher', 'manufacturer']) {
      final value = _text(node[field]);
      if (value.trim().isNotEmpty) return value;
    }
    return '';
  }

  static String _description(Map<String, Object?> node) {
    for (final field in const <String>[
      'description',
      'disambiguatingDescription',
    ]) {
      final value = _text(node[field]);
      if (value.trim().isNotEmpty) return value;
    }
    return '';
  }

  static String _platform(Map<String, Object?> node) {
    for (final field in const <String>[
      'gamePlatform',
      'platform',
      'operatingSystem',
    ]) {
      final value = _text(node[field]);
      if (value.trim().isNotEmpty) return value;
    }
    return '';
  }

  static int? _year(Map<String, Object?> node) {
    for (final field in const <String>[
      'datePublished',
      'releaseDate',
      'dateCreated',
    ]) {
      final value = _text(node[field]);
      if (value.isEmpty) continue;
      final match = RegExp(r'(1[0-9]{3}|2[0-9]{3})').firstMatch(value);
      if (match == null) continue;
      final year = int.tryParse(match.group(1)!);
      if (year != null && year >= 1 && year <= 9999) return year;
    }
    return null;
  }

  /// Only `Book` is unambiguous in JSON-LD; everything else stays null so the
  /// user is asked instead of being shown a guessed medium.
  static MediaType? _medium(Map<String, Object?> node) {
    final types = <String>{
      ..._typeNames(node['@type']),
      ..._typeNames(node['additionalType']),
    }.map((entry) => entry.toLowerCase());
    for (final type in types) {
      if (type.endsWith('book')) return MediaType.book;
    }
    return null;
  }

  static String? _imageUrl(Map<String, Object?> node) {
    for (final candidate in _stringValues(node['image'])) {
      final trimmed = candidate.trim();
      if (trimmed.isEmpty) continue;
      final uri = Uri.tryParse(trimmed);
      if (uri == null) continue;
      // Only hosts the cover downloader already trusts may be retained.
      if (CoverDownloader.isAllowedUri(uri)) return trimmed;
    }
    return null;
  }

  static String? _clip(String value, int maxLength) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length <= maxLength
        ? trimmed
        : trimmed.substring(0, maxLength);
  }

  /// Visible page text with scripts, styles and markup removed.
  ///
  /// Used as bounded evidence for the extraction model; it is data, never
  /// instructions.
  static String visibleText(String html) {
    var text = html;
    for (final pattern in <RegExp>[
      RegExp(r'<script\b.*?</script>', caseSensitive: false, dotAll: true),
      RegExp(r'<style\b.*?</style>', caseSensitive: false, dotAll: true),
      RegExp(r'<noscript\b.*?</noscript>', caseSensitive: false, dotAll: true),
      RegExp(r'<svg\b.*?</svg>', caseSensitive: false, dotAll: true),
      RegExp(r'<!--.*?-->', dotAll: true),
    ]) {
      text = text.replaceAll(pattern, ' ');
    }
    text = text.replaceAll(
      RegExp(r'<(br|/p|/div|/li|/h[1-6])\b[^>]*>', caseSensitive: false),
      '\n',
    );
    text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#x27;', "'");
    text = text.replaceAll(RegExp(r'[ \t\r\f]+'), ' ');
    text = text.replaceAll(RegExp(r'\n\s*\n+'), '\n');
    final trimmed = text.trim();
    return trimmed.length <= maxVisibleText
        ? trimmed
        : trimmed.substring(0, maxVisibleText);
  }
}

class _NodeBudget {
  _NodeBudget(this.remaining);

  int remaining;

  bool spend() {
    if (remaining <= 0) return false;
    remaining--;
    return true;
  }
}
