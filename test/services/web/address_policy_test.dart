import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/services/web/address_policy.dart';

void main() {
  group('page URI policy', () {
    test('accepts only public https on 443', () {
      expect(
        AddressPolicy.isAllowedPageUri(Uri.parse('https://shop.example/item')),
        isTrue,
      );
      expect(
        AddressPolicy.isAllowedPageUri(Uri.parse('https://shop.example:443/x')),
        isTrue,
      );
      expect(
        AddressPolicy.isAllowedPageUri(Uri.parse('http://shop.example/x')),
        isFalse,
      );
      expect(
        AddressPolicy.isAllowedPageUri(
          Uri.parse('https://shop.example:8443/x'),
        ),
        isFalse,
      );
      expect(
        AddressPolicy.isAllowedPageUri(
          Uri.parse('https://user:pw@shop.example'),
        ),
        isFalse,
      );
      expect(
        AddressPolicy.isAllowedPageUri(Uri.parse('file:///etc/passwd')),
        isFalse,
      );
    });

    test('rejects loopback, intranet and literal hosts', () {
      for (final host in <String>[
        'localhost',
        'api.localhost',
        'printer',
        'shop.internal',
        'nas.local',
        '127.0.0.1',
        '10.1.2.3',
        '169.254.169.254',
        '[::1]',
        '[2001:db8::1]',
      ]) {
        expect(
          AddressPolicy.isAllowedPageUri(Uri.parse('https://$host/item')),
          isFalse,
          reason: '$host must not be fetched',
        );
      }
    });
  });

  group('address policy', () {
    InternetAddress v4(String value) => InternetAddress(value);
    InternetAddress v6(String value) => InternetAddress(value);

    test('accepts ordinary public addresses', () {
      expect(AddressPolicy.isPublicAddress(v4('8.8.8.8')), isTrue);
      expect(AddressPolicy.isPublicAddress(v4('151.101.1.69')), isTrue);
      expect(AddressPolicy.isPublicAddress(v6('2606:4700::1111')), isTrue);
      expect(
        AddressPolicy.isPublicAddress(v6('2a00:1450:4001:80e::200e')),
        isTrue,
      );
    });

    test('rejects private, loopback and special IPv4 ranges', () {
      for (final value in <String>[
        '0.0.0.0',
        '10.0.0.1',
        '100.64.0.1',
        '127.0.0.1',
        '169.254.169.254',
        '172.16.0.1',
        '172.31.255.254',
        '192.0.0.1',
        '192.0.2.5',
        '192.88.99.1',
        '192.168.1.1',
        '198.18.0.1',
        '198.51.100.7',
        '203.0.113.9',
        '224.0.0.1',
        '255.255.255.255',
      ]) {
        expect(
          AddressPolicy.isPublicAddress(v4(value)),
          isFalse,
          reason: '$value must be rejected',
        );
      }
    });

    test('rejects private, loopback and special IPv6 ranges', () {
      for (final value in <String>[
        '::',
        '::1',
        'fc00::1',
        'fd12:3456::1',
        'fe80::1',
        'ff02::1',
        '100::1',
        '2001:db8::1',
        '2001:2::1',
        '2001:0:1234::1',
        '2001:3::1',
        '2001:20::1',
        '3fff::1',
        '5f00::1',
        '2620:4f:8000::1',
        'fec0::1',
      ]) {
        expect(
          AddressPolicy.isPublicAddress(v6(value)),
          isFalse,
          reason: '$value must be rejected',
        );
      }
    });

    test('refuses every non-global-unicast IPv6 form outright', () {
      // Conservative policy: only 2000::/3 minus special-purpose prefixes is
      // accepted, so mapped, NAT64, 6to4 and deprecated site-local forms fail
      // even when they embed a public IPv4 address.
      for (final value in <String>[
        '::ffff:10.0.0.1',
        '::ffff:8.8.8.8',
        '::10.0.0.1',
        '64:ff9b::8.8.8.8',
        '64:ff9b::127.0.0.1',
        '2002:0a00:0001::1',
        '2002:0808:0808::1',
        'fec0::1',
      ]) {
        expect(
          AddressPolicy.isPublicAddress(v6(value)),
          isFalse,
          reason: '$value must be refused by the global-unicast policy',
        );
      }
      // 2001:db8 cannot be resolved to a value in that list, so it is covered
      // by the special-purpose test above.
      expect(AddressPolicy.isPublicAddress(v6('2001:db8::1')), isFalse);
    });
  });
}
