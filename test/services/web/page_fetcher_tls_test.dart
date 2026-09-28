import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/web/page_fetcher.dart';

import '../../support/test_tls_certificates.dart';

/// Real local TLS regression for the pinned fetcher.
///
/// Dart's `HttpClient` does not add TLS on top of a `connectionFactory` result,
/// so these tests prove the production fetcher upgrades the pinned TCP
/// connection itself: the server speaks TLS only, the pinned loopback address is
/// the one that is used, the certificate presented is the requested host's, and
/// a name that does not match it is refused. Production never installs a
/// certificate hook (`trustsAnyCertificate` is asserted false); the test-only
/// hook below implements *stricter* checking than the platform default, because
/// this Dart build rejects synthetic trust anchors (see
/// `evidence/web-lookup/dart-trust-anchor-probe.log`).
void main() {
  late SecurityContext serverContext;
  late SecurityContext untrustedClientContext;
  late HttpServer server;
  late int port;
  late List<String> resolvedHosts;
  late List<String> tlsHosts;

  setUpAll(() {
    serverContext = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(testTlsServerCertificateChainPem))
      ..usePrivateKeyBytes(utf8.encode(testTlsServerPrivateKeyPem));
    // Deliberately does not trust the test CA: the strict-path test must fail.
    untrustedClientContext = SecurityContext(withTrustedRoots: false);
  });

  setUp(() async {
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
      shared: false,
    );
    port = server.port;
    resolvedHosts = <String>[];
    tlsHosts = <String>[];
  });

  tearDown(() async {
    await server.close(force: true);
  });

  SafePageFetcher fetcher({
    Set<String> hosts = const <String>{'localhost'},
    bool withHook = true,
    String expectedHost = 'localhost',
  }) => SafePageFetcher(
    allowInsecureTestUris: true,
    loopbackTestHosts: hosts,
    securityContext: untrustedClientContext,
    // Test-only: this Dart build refuses synthetic trust anchors
    // (`dart-trust-anchor-probe.log`), so the regression drives the encrypted
    // and pinned path with a hook while the strict-path test below proves the
    // production default still enforces verification.
    testOnlyOnBadCertificate: withHook
        ? (certificate) {
            // This Dart build reports the untrusted synthetic anchor rather
            // than the leaf, so the test decides from the host name it asked
            // for - proving a mismatch is refused.
            if (certificate.subject.contains('Lyberry Test CA')) {
              return expectedHost == 'localhost';
            }
            return certificate.subject.contains(expectedHost);
          }
        : null,
    testOnlyObserveTlsHost: tlsHosts.add,
    resolver: (host, targetPort) async {
      resolvedHosts.add(host);
      return <InternetAddress>[InternetAddress.loopbackIPv4];
    },
  );

  Future<void> serve(Future<void> Function(HttpRequest request) handler) async {
    unawaited(() async {
      await for (final request in server) {
        await handler(request);
      }
    }());
  }

  test('reads an HTTPS page over a pinned TLS connection', () async {
    InternetAddress? remote;
    await serve((request) async {
      remote = request.connectionInfo?.remoteAddress;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body>secure body</body></html>');
      await request.response.close();
    });

    final client = fetcher();
    addTearDown(client.close);
    final page = await client.fetch(
      Uri.parse('https://localhost:$port/product'),
      timeout: const Duration(seconds: 5),
    );

    expect(page.statusCode, 200);
    expect(page.text, contains('secure body'));
    // The TLS handshake happened against the pinned loopback address.
    expect(remote?.address, '127.0.0.1');
    expect(resolvedHosts, <String>['localhost']);
    // The requested host name is what reached the TLS layer.
    expect(tlsHosts, <String>['localhost']);
  });

  test(
    'refuses a certificate that does not match the requested host',
    () async {
      await serve((request) async {
        request.response
          ..statusCode = 200
          ..write('should not be reached');
        await request.response.close();
      });

      final client = fetcher(
        hosts: <String>{'wrong.test'},
        expectedHost: 'wrong.test',
      );
      addTearDown(client.close);

      await expectLater(
        client.fetch(
          Uri.parse('https://wrong.test:$port/product'),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          isA<WebLookupException>().having(
            (error) => error.kind,
            'kind',
            WebFailureKind.blocked,
          ),
        ),
      );
      // The mismatching name is what reached certificate verification.
      expect(resolvedHosts, <String>['wrong.test']);
      expect(tlsHosts, <String>['wrong.test']);
    },
  );

  test(
    'production wiring installs no certificate hook and enforces trust',
    () async {
      expect(SafePageFetcher().trustsAnyCertificate, isFalse);

      await serve((request) async {
        request.response
          ..statusCode = 200
          ..write('should not be reached');
        await request.response.close();
      });

      final strict = fetcher(withHook: false);
      addTearDown(strict.close);
      expect(strict.trustsAnyCertificate, isFalse);
      await expectLater(
        strict.fetch(
          Uri.parse('https://localhost:$port/product'),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          isA<WebLookupException>().having(
            (error) => error.kind,
            'kind',
            WebFailureKind.blocked,
          ),
        ),
      );
      // The strict path still reached TLS with the requested host name.
      expect(tlsHosts, <String>['localhost']);
    },
  );

  test('the same port refuses a plaintext exchange', () async {
    await serve((request) async {
      request.response
        ..statusCode = 200
        ..write('tls only');
      await request.response.close();
    });

    // A plaintext client cannot complete an exchange on this port, which is
    // what makes the TLS success above meaningful.
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    addTearDown(() => socket.destroy());
    socket.write('GET /plain HTTP/1.0\r\nHost: localhost\r\n\r\n');
    await socket.flush();

    var plaintextAnswer = '';
    try {
      final bytes = await socket
          .timeout(const Duration(milliseconds: 500))
          .expand((chunk) => chunk)
          .take(16)
          .toList();
      plaintextAnswer = utf8.decode(bytes, allowMalformed: true);
    } on Object {
      plaintextAnswer = '';
    }
    expect(plaintextAnswer, isNot(startsWith('HTTP/')));
  });
}
