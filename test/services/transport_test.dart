import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/transport.dart';

/// A local HTTP server so the transport is exercised against a real socket
/// without touching any live service.
Future<HttpServer> startServer(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    handler(request).catchError((Object _) {});
  });
  return server;
}

void main() {
  test('rejects non-https urls unless the test seam is enabled', () async {
    final transport = IoHttpTransport();
    await expectLater(
      transport.get(Uri.parse('http://127.0.0.1:1/x')),
      throwsA(
        isA<TransportException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.unavailable,
        ),
      ),
    );
  });

  test('enforces one overall deadline across a trickling body', () async {
    final server = await startServer((request) async {
      request.response.statusCode = 200;
      request.response.write('{"a":');
      await request.response.flush();
      // Keep trickling well past the client deadline without finishing.
      for (var index = 0; index < 40; index++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        request.response.write(' ');
        await request.response.flush();
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final transport = IoHttpTransport(allowInsecureTestUris: true);
    final started = DateTime.now();
    await expectLater(
      transport.get(
        Uri.parse('http://127.0.0.1:${server.port}/slow'),
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(
        isA<TransportException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.timeout,
        ),
      ),
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 3)),
      reason: 'the deadline must cover the whole body, not just the headers',
    );
  });

  test('aborts a response that exceeds the byte cap', () async {
    final server = await startServer((request) async {
      request.response.statusCode = 200;
      final chunk = List<int>.filled(64 * 1024, 0x41);
      for (var index = 0; index < 8; index++) {
        request.response.add(chunk);
        await request.response.flush();
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final transport = IoHttpTransport(allowInsecureTestUris: true);
    await expectLater(
      transport.get(
        Uri.parse('http://127.0.0.1:${server.port}/big'),
        maxBytes: 32 * 1024,
      ),
      throwsA(
        isA<TransportException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.unavailable,
        ),
      ),
    );
  });

  test('normalises a failure in the middle of the body', () async {
    // A raw socket lets the server promise more bytes than it sends and then
    // drop the connection, which the client must report as a network failure.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      socket.write(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: 100\r\n'
        'Connection: close\r\n\r\n'
        '{"partial":',
      );
      socket.flush().then((_) => socket.destroy());
    });
    addTearDown(() => server.close());

    final transport = IoHttpTransport(allowInsecureTestUris: true);
    await expectLater(
      transport.get(Uri.parse('http://127.0.0.1:${server.port}/broken')),
      throwsA(
        isA<TransportException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.network,
        ),
      ),
    );
  });

  test('returns a complete body and normalised headers', () async {
    final server = await startServer((request) async {
      request.response.statusCode = 200;
      request.response.headers.set('X-Test', 'yes');
      request.response.write('{"ok":true}');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final transport = IoHttpTransport(allowInsecureTestUris: true);
    final response = await transport.get(
      Uri.parse('http://127.0.0.1:${server.port}/ok'),
    );

    expect(response.statusCode, 200);
    expect(response.body, '{"ok":true}');
    expect(response.header('x-test'), 'yes');
  });
}
