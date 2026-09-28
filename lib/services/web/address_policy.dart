import 'dart:io';

/// Host and address rules for the dedicated public-page fetcher.
///
/// The fetcher validates a destination here *and* pins the approved address it
/// resolved, so a second DNS answer cannot redirect the connection somewhere
/// private between validation and connect.
abstract final class AddressPolicy {
  /// Schemes, ports and host shapes the page fetcher accepts.
  ///
  /// Only public HTTPS on 443 is allowed: no userinfo, no literal addresses
  /// (IPv4 or IPv6), no `localhost`, no single-label intranet names.
  static bool isAllowedPageUri(Uri uri) {
    if (uri.scheme != 'https') return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (uri.hasPort && uri.port != 443) return false;
    final host = uri.host;
    if (host.isEmpty) return false;
    if (isBlockedHostName(host)) return false;
    return true;
  }

  /// True for names the fetcher never resolves: loopback, bracketed IPv6
  /// literals, dotted-quad literals and single-label hosts.
  static bool isBlockedHostName(String host) {
    final lower = host.toLowerCase();
    if (lower.isEmpty) return true;
    if (lower.startsWith('[') || lower.endsWith(']')) return true;
    if (lower == 'localhost' || lower.endsWith('.localhost')) return true;
    if (lower.endsWith('.local') || lower.endsWith('.internal')) return true;
    if (_looksLikeIpv4Literal(lower)) return true;
    if (lower.contains(':')) return true; // unbracketed IPv6 literal
    if (!lower.contains('.')) return true; // single-label intranet host
    if (lower.endsWith('.')) return true;
    return false;
  }

  static bool _looksLikeIpv4Literal(String lower) {
    final parts = lower.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return false;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
    }
    return true;
  }

  /// True only for globally routable unicast addresses.
  ///
  /// Rejects loopback, private, link-local, CGNAT, multicast, unspecified,
  /// documentation, benchmarking and reserved ranges. The IPv6 policy is
  /// deliberately conservative: only global unicast (`2000::/3`) minus the
  /// special-purpose prefixes inside it is accepted, so site-local
  /// (`fec0::/10`), unique local (`fc00::/7`), link-local, multicast, mapped
  /// (`::ffff:0:0/96`), NAT64 (`64:ff9b::/96`) and 6to4 (`2002::/16`) forms are
  /// all refused.
  static bool isPublicAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) return _isPublicIpv4(bytes);
    if (bytes.length == 16) return _isPublicIpv6(bytes);
    return false;
  }

  static bool _isPublicIpv4(List<int> b) {
    final a = b[0];
    final second = b[1];
    if (a == 0) return false; // 0.0.0.0/8 "this network"
    if (a == 10) return false; // private
    if (a == 127) return false; // loopback
    if (a == 100 && second >= 64 && second <= 127) return false; // CGNAT
    if (a == 169 && second == 254) return false; // link-local
    if (a == 172 && second >= 16 && second <= 31) return false; // private
    if (a == 192 && second == 0 && b[2] == 0) return false; // IETF protocol
    if (a == 192 && second == 0 && b[2] == 2) return false; // TEST-NET-1
    if (a == 192 && second == 88 && b[2] == 99) return false; // 6to4 relay
    if (a == 192 && second == 168) return false; // private
    if (a == 198 && (second == 18 || second == 19)) return false; // benchmark
    if (a == 198 && second == 51 && b[2] == 100) return false; // TEST-NET-2
    if (a == 203 && second == 0 && b[2] == 113) return false; // TEST-NET-3
    if (a >= 224) return false; // multicast, reserved and broadcast
    return true;
  }

  static bool _isPublicIpv6(List<int> b) {
    // Global unicast is 2000::/3. Everything else - unspecified, loopback,
    // unique local, link-local, deprecated site-local, multicast, IPv4-mapped,
    // NAT64 and other transitional forms - fails this first check.
    if ((b[0] & 0xe0) != 0x20) return false;

    final second = b[1];
    final third = b[2];
    if (b[0] == 0x20 && second == 0x01) {
      // The second IPv6 group (2001:xxxx::) lands in bytes 2 and 3.
      if (third == 0x00) {
        final group = b[3];
        if (group == 0x00) return false; // 2001::/32 Teredo
        if (group == 0x02) return false; // 2001:2::/48 benchmarking
        if (group == 0x03) return false; // 2001:3::/32 AMT
        if (group >= 0x10 && group <= 0x1f) return false; // 2001:10::/28
        if (group >= 0x20 && group <= 0x2f) return false; // 2001:20::/28
      }
      if (third == 0x0d && b[3] == 0xb8) return false; // 2001:db8::/32 docs
    }
    if (b[0] == 0x20 && second == 0x02) return false; // 2002::/16 6to4
    if (b[0] == 0x3f && (second & 0xf0) == 0xf0) {
      return false; // 3fff::/20 documentation
    }
    if (b[0] == 0x5f && second == 0x00) return false; // 5f00::/16 SRv6 SIDs
    if (b[0] == 0x26 &&
        second == 0x20 &&
        third == 0x00 &&
        b[3] == 0x4f &&
        b[4] == 0x80 &&
        b[5] == 0x00) {
      return false; // 2620:4f:8000::/48 AS112
    }
    return true;
  }
}
