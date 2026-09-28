import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/web/product_extractor.dart';

const String kCode = '5051888100639';

bool matches(String digits) => digits == kCode;

String pageWith(String jsonLd, {String extra = ''}) =>
    '<html><head><title>Shop</title></head><body>'
    '<script type="application/ld+json">$jsonLd</script>'
    '$extra</body></html>';

void main() {
  test('extracts a Product whose own GTIN matches', () {
    final html = pageWith(
      jsonEncode(<String, Object?>{
        '@context': 'https://schema.org',
        '@type': 'Product',
        'name': 'Matrix',
        'gtin13': kCode,
        'brand': <String, Object?>{'@type': 'Brand', 'name': 'Warner Bros.'},
        'publisher': <String, Object?>{'name': 'Warner Bros. Home Ent.'},
        'releaseDate': '2008-09-26',
        'description': 'The first film in the series.',
        'image': 'https://m.media-amazon.com/images/I/x.jpg',
      }),
    );

    final extraction = ProductExtractor.extract(html, matchesCode: matches);
    expect(extraction.products, hasLength(1));
    final product = extraction.products.single;
    expect(product.title, 'Matrix');
    expect(product.matchedCode, kCode);
    expect(product.creator, 'Warner Bros.');
    expect(product.publisher, 'Warner Bros. Home Ent.');
    expect(product.year, 2008);
    expect(product.description, 'The first film in the series.');
    expect(product.coverUrl, 'https://m.media-amazon.com/images/I/x.jpg');
  });

  test('a GTIN that is only mentioned elsewhere never matches', () {
    final html = pageWith(
      jsonEncode(<String, Object?>{
        '@context': 'https://schema.org',
        '@type': 'Product',
        'name': 'Unrelated recommendation',
        'gtin13': '9999999999999',
      }),
      extra: '<p>Customers also viewed barcode $kCode</p>',
    );

    final extraction = ProductExtractor.extract(html, matchesCode: matches);
    expect(extraction.products, isEmpty);
    // The code is still in the visible text, so the evidence gate can judge it.
    expect(extraction.visibleText, contains(kCode));
  });

  test('walks @graph and nested arrays', () {
    final html = pageWith(
      jsonEncode(<String, Object?>{
        '@context': 'https://schema.org',
        '@graph': <Object?>[
          <String, Object?>{
            '@type': <String>['WebSite'],
            'name': 'Shop',
          },
          <String, Object?>{
            '@type': <String>['Product', 'Book'],
            'name': 'Nested book',
            'gtin': kCode,
          },
        ],
      }),
    );

    final extraction = ProductExtractor.extract(html, matchesCode: matches);
    expect(extraction.products, hasLength(1));
    expect(extraction.products.single.title, 'Nested book');
    expect(extraction.products.single.medium, MediaType.book);
  });

  test('reads a Product inside a list value', () {
    final html = pageWith(
      jsonEncode(<String, Object?>{
        '@context': 'https://schema.org',
        'itemListElement': <Object?>[
          <String, Object?>{
            '@type': 'Product',
            'name': 'First',
            'gtin12': '0$kCode'.substring(0, 12),
          },
          <String, Object?>{
            '@type': 'Product',
            'name': 'Second',
            'gtin13': kCode,
          },
        ],
      }),
    );

    final extraction = ProductExtractor.extract(html, matchesCode: matches);
    expect(extraction.products.map((product) => product.title), <String>[
      'Second',
    ]);
  });

  test('ignores malformed, oversized and deeply nested JSON-LD', () {
    final deep = StringBuffer();
    for (var index = 0; index < 60; index++) {
      deep.write('{"child":');
    }
    deep.write('{"@type":"Product","name":"Too deep","gtin13":"$kCode"}');
    for (var index = 0; index < 60; index++) {
      deep.write('}');
    }

    final html =
        '<html><body>'
        '<script type="application/ld+json">{not json}</script>'
        '<script type="application/ld+json">${'x' * (600 * 1024)}</script>'
        '<script type="application/ld+json">$deep</script>'
        '</body></html>';

    final extraction = ProductExtractor.extract(html, matchesCode: matches);
    expect(extraction.products, isEmpty);
  });

  test('only keeps cover images from allowlisted hosts', () {
    final html = pageWith(
      jsonEncode(<String, Object?>{
        '@type': 'Product',
        'name': 'Matrix',
        'gtin13': kCode,
        'image': 'https://evil.example/track.jpg',
      }),
    );
    final extraction = ProductExtractor.extract(html, matchesCode: matches);
    expect(extraction.products.single.coverUrl, isNull);
  });

  test('clips oversized fields instead of passing them through', () {
    final html = pageWith(
      jsonEncode(<String, Object?>{
        '@type': 'Product',
        'name': 'N' * 900,
        'gtin13': kCode,
        'description': 'D' * 9000,
      }),
    );
    final extraction = ProductExtractor.extract(html, matchesCode: matches);
    final product = extraction.products.single;
    expect(product.title.length, ProductExtractor.maxFieldLength);
    expect(product.description.length, ProductExtractor.maxDescriptionLength);
  });

  test('visible text drops scripts, styles and markup', () {
    final html =
        '<html><head><style>body{color:red}</style></head>'
        '<body><script>var x = "ignore me";</script>'
        '<!-- comment --><h1>Matrix &amp; Argo</h1><p>Barcode $kCode</p>'
        '</body></html>';
    final text = ProductExtractor.visibleText(html);
    expect(text, contains('Matrix & Argo'));
    expect(text, contains(kCode));
    expect(text, isNot(contains('ignore me')));
    expect(text, isNot(contains('color:red')));
    expect(text, isNot(contains('comment')));
  });
}
