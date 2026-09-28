import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/user_agent.dart';
import 'package:lyberry/services/web/address_policy.dart';

/// One raw page answer from the dedicated fetcher.
class FetchedPage {
  const FetchedPage({
    required this.uri,
    required this.statusCode,
    required this.contentType,
    required this.bytes,
    this.redirectedFrom,
  });

  final Uri uri;
  final int statusCode;
  final String? contentType;
  final Uint8List bytes;
  final Uri? redirectedFrom;

  bool get isSuccess => statusCode == 200;

  bool get isTextual {
    final type = contentType?.toLowerCase();
    if (type == null || type.isEmpty) return true;
    return type.startsWith('text/') ||
        type.contains('html') ||
        type.contains('json') ||
        type.contains('xml');
  }

  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// Fetches public product pages with the security boundary the brief requires.
abstract interface class PageFetcher {
  Future<FetchedPage> fetch(
    Uri uri, {
    required Duration timeout,
    int maxBytes,
    bool Function()? isCancelled,
  });

  /// Releases any pooled resources. Always safe to call.
  void close();
}

typedef AddressResolver =
    Future<List<InternetAddress>> Function(String host, int port);

/// Production fetcher: HTTPS/443 only, DNS pinned, redirects re-validated.
class SafePageFetcher implements PageFetcher {
  SafePageFetcher({
    AddressResolver? resolver,
    bool allowInsecureTestUris = false,
    SecurityContext? securityContext,
    Set<String> loopbackTestHosts = const <String>{},
    bool Function(X509Certificate certificate)? testOnlyOnBadCertificate,
    void Function(String host)? testOnlyObserveTlsHost,
    this.maxRedirects = 2,
  }) : _resolver =
           resolver ??
           ((host, port) =>
               InternetAddress.lookup(host, type: InternetAddressType.any)),
       _allowInsecureTestUris = allowInsecureTestUris,
       _securityContext = securityContext,
       _testOnlyOnBadCertificate = testOnlyOnBadCertificate,
       _testOnlyObserveTlsHost = testOnlyObserveTlsHost,
       _loopbackTestHosts = loopbackTestHosts;

  static const int defaultMaxBytes = 1024 * 1024;
  static const Duration defaultTimeout = Duration(seconds: 10);

  final AddressResolver _resolver;
  final bool _allowInsecureTestUris;

  /// Test-only trust store; production always uses the platform default.
  final SecurityContext? _securityContext;

  /// Test-only certificate hook. Production never sets it, so the platform
  /// trust store and hostname verification always apply.
  final bool Function(X509Certificate certificate)? _testOnlyOnBadCertificate;

  /// Test-only observation point for the host name handed to TLS.
  final void Function(String host)? _testOnlyObserveTlsHost;

  /// Test-only host names allowed to resolve to loopback.
  final Set<String> _loopbackTestHosts;
  final int maxRedirects;

  /// True when a test injected a certificate hook. Production is always false.
  bool get trustsAnyCertificate => _testOnlyOnBadCertificate != null;

  @override
  void close() {}

  @override
  Future<FetchedPage> fetch(
    Uri uri, {
    required Duration timeout,
    int maxBytes = defaultMaxBytes,
    bool Function()? isCancelled,
  }) async {
    if (timeout <= Duration.zero) {
      throw const WebLookupException(
        WebFailureKind.timeout,
        'The page had no time left.',
      );
    }
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    var current = uri;
    Uri? redirectedFrom;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (isCancelled?.call() ?? false) {
        throw const WebLookupException(
          WebFailureKind.cancelled,
          'The page request was cancelled.',
        );
      }
      if (remaining() <= Duration.zero) {
        throw const WebLookupException(
          WebFailureKind.timeout,
          'The page did not answer in time.',
        );
      }
      _requireAllowed(current);
      final List<InternetAddress> addresses;
      try {
        addresses = await _resolve(current.host).timeout(remaining());
      } on TimeoutException {
        // DNS is inside the same deadline; map it like any other stage timeout.
        throw const WebLookupException(
          WebFailureKind.timeout,
          'The page host did not answer in time.',
        );
      }
      var pinned = addresses.where(AddressPolicy.isPublicAddress).toList();
      // Test-only seam: the local in-process servers live on loopback, which
      // the production policy rejects. Everything else still applies.
      final testLoopback = _isTestHost(current.host);
      if (pinned.isEmpty && testLoopback) {
        pinned = addresses.toList();
      }
      if (pinned.isEmpty) {
        throw const WebLookupException(
          WebFailureKind.blocked,
          'That address is not a public internet host.',
        );
      }

      final page = await _singleRequest(
        current,
        pinned.first,
        remaining: remaining,
        maxBytes: maxBytes,
        isCancelled: isCancelled,
      );
      final location = page.redirectLocation;
      if (location != null) {
        if (hop == maxRedirects) {
          throw const WebLookupException(
            WebFailureKind.blocked,
            'The page redirected too many times.',
          );
        }
        final next = current.resolve(location.trim());
        _requireAllowed(next);
        redirectedFrom ??= current;
        current = next;
        continue;
      }
      return FetchedPage(
        uri: current,
        statusCode: page.statusCode,
        contentType: page.contentType,
        bytes: page.bytes,
        redirectedFrom: redirectedFrom,
      );
    }
    throw const WebLookupException(
      WebFailureKind.blocked,
      'The page redirected too many times.',
    );
  }

  void _requireAllowed(Uri uri) {
    final allowed =
        AddressPolicy.isAllowedPageUri(uri) ||
        (_isTestHost(uri.host) &&
            uri.userInfo.isEmpty &&
            (uri.scheme == 'http' || uri.scheme == 'https'));
    if (!allowed) {
      throw const WebLookupException(
        WebFailureKind.blocked,
        'Only public https pages can be read.',
      );
    }
  }

  /// True only for the explicitly whitelisted test hosts, and only when the
  /// insecure-test seam is on.
  bool _isTestHost(String host) =>
      _allowInsecureTestUris &&
      (host == '127.0.0.1' || _loopbackTestHosts.contains(host));

  Future<List<InternetAddress>> _resolve(String host) async {
    try {
      return await _resolver(host, 443);
    } on Object {
      throw const WebLookupException(
        WebFailureKind.network,
        'That host could not be resolved.',
      );
    }
  }

  Future<_RawPage> _singleRequest(
    Uri uri,
    InternetAddress pinned, {
    required Duration Function() remaining,
    required int maxBytes,
    bool Function()? isCancelled,
  }) async {
    final client = HttpClient();
    // Proxies are disabled for this dedicated fetcher.
    client.findProxy = (target) => 'DIRECT';
    // Dart does NOT add TLS on top of a connectionFactory result, so the
    // factory must hand back an already-secured socket. The TCP connection is
    // pinned to the validated address, then upgraded locally with SNI and the
    // normal certificate check for the original host name.
    final connector = _PinnedTlsConnector(
      address: pinned,
      port: uri.port,
      host: uri.host,
      secure: uri.scheme == 'https',
      context: _securityContext ?? SecurityContext.defaultContext,
      onBadCertificate: _testOnlyOnBadCertificate,
      observeTlsHost: _testOnlyObserveTlsHost,
    );
    client.connectionFactory = (target, proxyHost, proxyPort) async =>
        connector.connect();
    client.userAgent = lyberryUserAgent();

    void abort() {
      connector.cancel();
      try {
        client.close(force: true);
      } on Object {
        // Closing twice is not interesting.
      }
    }

    try {
      final request = await client.getUrl(uri).timeout(remaining());
      request.followRedirects = false;
      request.headers.set(
        'accept',
        'text/html,application/xhtml+xml,application/json;q=0.8,text/plain;q=0.5',
      );
      final response = await request.close().timeout(remaining());
      final bytes = await _readBounded(
        response,
        maxBytes: maxBytes,
        remaining: remaining,
        abort: abort,
        isCancelled: isCancelled,
      );
      return _RawPage(
        statusCode: response.statusCode,
        contentType: response.headers.value(HttpHeaders.contentTypeHeader),
        bytes: bytes,
        redirectLocation: _isRedirect(response.statusCode)
            ? response.headers.value(HttpHeaders.locationHeader)
            : null,
      );
    } on TimeoutException {
      abort();
      throw const WebLookupException(
        WebFailureKind.timeout,
        'The page did not answer in time.',
      );
    } on WebLookupException {
      abort();
      rethrow;
    } on HandshakeException {
      abort();
      throw const WebLookupException(
        WebFailureKind.blocked,
        'The page certificate could not be verified.',
      );
    } on SocketException {
      abort();
      throw const WebLookupException(
        WebFailureKind.network,
        'The page could not be reached.',
      );
    } on HttpException {
      abort();
      throw const WebLookupException(
        WebFailureKind.network,
        'The page closed the connection early.',
      );
    } finally {
      abort();
    }
  }

  Future<Uint8List> _readBounded(
    HttpClientResponse response, {
    required int maxBytes,
    required Duration Function() remaining,
    required void Function() abort,
    bool Function()? isCancelled,
  }) {
    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    late StreamSubscription<List<int>> subscription;
    Timer? timer;
    var finished = false;
    Timer? cancelTimer;

    void finish(FutureOr<void> Function() complete) {
      if (finished) return;
      finished = true;
      timer?.cancel();
      cancelTimer?.cancel();
      complete();
    }

    void fail(Object error) {
      finish(() {
        subscription.cancel();
        abort();
        if (!completer.isCompleted) completer.completeError(error);
      });
    }

    subscription = response.listen(
      (chunk) {
        if (finished) return;
        if (isCancelled?.call() ?? false) {
          fail(
            const WebLookupException(
              WebFailureKind.cancelled,
              'The page request was cancelled.',
            ),
          );
          return;
        }
        builder.add(chunk);
        if (builder.length > maxBytes) {
          fail(
            WebLookupException(
              WebFailureKind.noContent,
              'The page was larger than ${maxBytes ~/ 1024} KiB.',
            ),
          );
        }
      },
      onError: (Object error) {
        fail(
          const WebLookupException(
            WebFailureKind.network,
            'The page could not be read.',
          ),
        );
      },
      onDone: () {
        finish(() {
          if (!completer.isCompleted) completer.complete(builder.takeBytes());
        });
      },
      cancelOnError: true,
    );

    if (isCancelled != null) {
      // A stalled socket may not deliver another chunk, so cancellation is also
      // polled: the user's stop must abort the request, not wait for the server.
      cancelTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (finished) return;
        if (isCancelled()) {
          fail(
            const WebLookupException(
              WebFailureKind.cancelled,
              'The page request was cancelled.',
            ),
          );
        }
      });
    }

    final left = remaining();
    if (left <= Duration.zero) {
      fail(
        const WebLookupException(
          WebFailureKind.timeout,
          'The page did not finish in time.',
        ),
      );
    } else {
      timer = Timer(left, () {
        fail(
          const WebLookupException(
            WebFailureKind.timeout,
            'The page did not finish in time.',
          ),
        );
      });
    }
    return completer.future;
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;
}

class _RawPage {
  const _RawPage({
    required this.statusCode,
    required this.contentType,
    required this.bytes,
    required this.redirectLocation,
  });

  final int statusCode;
  final String? contentType;
  final Uint8List bytes;
  final String? redirectLocation;
}

/// Pins one validated address and, for HTTPS, upgrades that exact TCP
/// connection to TLS without resolving the host again.
///
/// Dart's `HttpClient` does not add TLS on top of a `connectionFactory` result,
/// so the factory has to return an already-secured socket. `SecureSocket.secure`
/// is given the original host name, so SNI and hostname verification keep using
/// it and the platform trust store is used (the injected context is test-only).
/// [cancel] destroys the raw socket, the secured socket and any socket produced
/// after the cancellation, so a late connection cannot outlive the request.
class _PinnedTlsConnector {
  _PinnedTlsConnector({
    required this.address,
    required this.port,
    required this.host,
    required this.secure,
    required this.context,
    required this.onBadCertificate,
    required this.observeTlsHost,
  });

  final InternetAddress address;
  final int port;
  final String host;
  final bool secure;
  final SecurityContext context;
  final bool Function(X509Certificate certificate)? onBadCertificate;
  final void Function(String host)? observeTlsHost;

  final List<Socket> _sockets = <Socket>[];
  bool _cancelled = false;

  ConnectionTask<Socket> connect() {
    if (_cancelled) {
      return ConnectionTask.fromSocket(
        Future<Socket>.error(
          const SocketException('Connection attempt cancelled.'),
        ),
        () {},
      );
    }
    return ConnectionTask.fromSocket(_open(), cancel);
  }

  Future<Socket> _open() async {
    final raw = await Socket.connect(address, port);
    _track(raw);
    _throwIfCancelled(raw);
    if (!secure) return raw;
    observeTlsHost?.call(host);
    final secured = await SecureSocket.secure(
      raw,
      host: host,
      context: context,
      onBadCertificate: onBadCertificate,
    );
    _track(secured);
    _throwIfCancelled(secured);
    return secured;
  }

  void _track(Socket socket) {
    if (_cancelled) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
  }

  void _throwIfCancelled(Socket socket) {
    if (!_cancelled) return;
    socket.destroy();
    throw const SocketException('Connection attempt cancelled.');
  }

  void cancel() {
    _cancelled = true;
    final sockets = List<Socket>.of(_sockets);
    _sockets.clear();
    for (final socket in sockets) {
      try {
        socket.destroy();
      } on Object {
        // The socket may already be closed by the client.
      }
    }
  }
}
