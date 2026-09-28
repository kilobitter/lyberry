import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/services/cover_downloader.dart';

import '../support/fake_transport.dart';
import '../support/test_support.dart';

void main() {
  group('cover host policy', () {
    test('accepts allowlisted HTTPS hosts and their archive subdomains', () {
      expect(
        CoverDownloader.isAllowedUri(
          Uri.parse('https://covers.openlibrary.org/b/id/1-L.jpg'),
        ),
        isTrue,
      );
      expect(
        CoverDownloader.isAllowedUri(
          Uri.parse('https://ia800100.us.archive.org/cover.jpg'),
        ),
        isTrue,
      );
      expect(
        CoverDownloader.isAllowedUri(
          Uri.parse('https://i.ebayimg.com/images/x.jpg'),
        ),
        isTrue,
      );
    });

    test('rejects http, odd ports, userinfo and unknown hosts', () {
      expect(
        CoverDownloader.isAllowedUri(
          Uri.parse('http://covers.openlibrary.org/a.jpg'),
        ),
        isFalse,
      );
      expect(
        CoverDownloader.isAllowedUri(
          Uri.parse('https://covers.openlibrary.org:8443/a.jpg'),
        ),
        isFalse,
      );
      expect(
        CoverDownloader.isAllowedUri(
          Uri.parse('https://user:pass@covers.openlibrary.org/a.jpg'),
        ),
        isFalse,
      );
      expect(
        CoverDownloader.isAllowedUri(
          Uri.parse('https://evil.example.com/a.jpg'),
        ),
        isFalse,
      );
    });

    test('rejects loopback, private, link-local and literal addresses', () {
      for (final host in <String>[
        'localhost',
        '127.0.0.1',
        '0.0.0.0',
        '10.0.0.5',
        '172.16.9.9',
        '192.168.1.10',
        '169.254.1.1',
        '[::1]',
      ]) {
        expect(CoverDownloader.isBlockedHost(host), isTrue, reason: host);
      }
      expect(CoverDownloader.isBlockedHost('covers.openlibrary.org'), isFalse);
    });
  });

  group('cover download', () {
    test(
      'downloads and validates an image, then serves it from cache',
      () async {
        final transport = FakeHttpTransport();
        final url = 'https://covers.openlibrary.org/b/id/1-L.jpg';
        transport.answerBytes(url, pngBytes(width: 40, height: 30));
        final downloader = CoverDownloader(transport: transport);

        final asset = await downloader.download(url);
        expect(asset, isNotNull);
        expect(asset!.mimeType, AssetMime.png);
        expect(asset.width, 40);
        expect(downloader.cacheLength, 1);

        await downloader.download(url);
        expect(transport.requests, hasLength(1), reason: 'cache hit');
      },
    );

    test('follows a validated redirect and honours the hop cap', () async {
      final transport = FakeHttpTransport();
      final start = 'https://coverartarchive.org/release/1/front-250';
      final middle = 'https://ia800100.us.archive.org/cover.jpg';
      transport.answer(
        start,
        body: '',
        status: 302,
        headers: <String, String>{'Location': middle},
      );
      transport.answerBytes(middle, pngBytes(width: 20, height: 20));

      final asset = await CoverDownloader(transport: transport).download(start);
      expect(asset, isNotNull);
      expect(transport.requests.map((uri) => uri.host).toList(), <String>[
        'coverartarchive.org',
        'ia800100.us.archive.org',
      ]);
    });

    test('refuses a redirect to a host outside the allowlist', () async {
      final transport = FakeHttpTransport();
      final start = 'https://coverartarchive.org/release/1/front-250';
      transport.answer(
        start,
        body: '',
        status: 302,
        headers: <String, String>{
          'Location': 'https://evil.example.com/steal.jpg',
        },
      );

      expect(
        await CoverDownloader(transport: transport).download(start),
        isNull,
      );
      expect(transport.requests, hasLength(1));
    });

    test('refuses a redirect to a private address', () async {
      final transport = FakeHttpTransport();
      final start = 'https://coverartarchive.org/release/1/front-250';
      transport.answer(
        start,
        body: '',
        status: 302,
        headers: <String, String>{'Location': 'https://127.0.0.1/secret.png'},
      );

      expect(
        await CoverDownloader(transport: transport).download(start),
        isNull,
      );
    });

    test('gives up after too many redirects', () async {
      final transport = FakeHttpTransport();
      final start = 'https://coverartarchive.org/release/1/front-250';
      final second = 'https://coverartarchive.org/release/2/front-250';
      final third = 'https://coverartarchive.org/release/3/front-250';
      final fourth = 'https://coverartarchive.org/release/4/front-250';
      final fifth = 'https://coverartarchive.org/release/5/front-250';
      transport.answer(
        start,
        body: '',
        status: 302,
        headers: <String, String>{'Location': second},
      );
      transport.answer(
        second,
        body: '',
        status: 302,
        headers: <String, String>{'Location': third},
      );
      transport.answer(
        third,
        body: '',
        status: 302,
        headers: <String, String>{'Location': fourth},
      );
      transport.answer(
        fourth,
        body: '',
        status: 302,
        headers: <String, String>{'Location': fifth},
      );
      transport.answerBytes(fifth, pngBytes());

      expect(
        await CoverDownloader(transport: transport).download(start),
        isNull,
      );
    });

    test('rejects oversized and non-image payloads', () async {
      final transport = FakeHttpTransport();
      final url = 'https://coverartarchive.org/release/9/front-250';
      transport.answerBytes(url, pngBytes(width: 200, height: 200));

      final downloader = CoverDownloader(transport: transport, maxBytes: 64);
      expect(await downloader.download(url), isNull);

      final textTransport = FakeHttpTransport();
      textTransport.answer(url, body: 'not an image at all');
      expect(
        await CoverDownloader(transport: textTransport).download(url),
        isNull,
      );
    });
  });
}
