// Opt-in host-side smoke check through the real providers and transport.
//
//   dart run tool/live_provider_smoke.dart
//
// Sends three public sample codes only (two HTTP requests for Open Library,
// one each for MusicBrainz and UPCitemdb), respects the same throttling as the
// app, never retries automatically and appends the result to
// docs/agent-work/lyberry/evidence/p2/live-smoke.log.
import 'dart:io';

import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/providers/musicbrainz_provider.dart';
import 'package:lyberry/services/providers/open_library_provider.dart';
import 'package:lyberry/services/providers/upcitemdb_provider.dart';
import 'package:lyberry/services/rate_limiter.dart';
import 'package:lyberry/services/transport.dart';

Future<void> main() async {
  const clock = SystemClock();
  final transport = IoHttpTransport();
  final limiters = <String, ProviderRateLimiter>{
    'openlibrary': ProviderRateLimiter(
      providerId: 'openlibrary',
      minInterval: const Duration(milliseconds: 1100),
      clock: clock,
    ),
    'musicbrainz': ProviderRateLimiter(
      providerId: 'musicbrainz',
      minInterval: const Duration(milliseconds: 1100),
      clock: clock,
    ),
    'upcitemdb': ProviderRateLimiter(
      providerId: 'upcitemdb',
      minInterval: const Duration(seconds: 10),
      clock: clock,
    ),
  };

  final log = StringBuffer()
    ..writeln('Lyberry live provider smoke (${DateTime.now().toUtc()})')
    ..writeln(
      'Codes: 9780306406157 (book), 0724384654726 (CD), '
      '5051892202657 (Blu-ray)',
    )
    ..writeln('Only public sample codes are sent; no library data.');

  Future<void> run(String label, MetadataProvider provider, String code) async {
    final query = LookupQuery(identifier: IdentifierNormalizer.normalize(code));
    final started = DateTime.now();
    try {
      final result = await provider.lookup(query);
      final elapsed = DateTime.now().difference(started);
      final first = result.candidates.isEmpty
          ? 'no candidates'
          : '${result.candidates.length} candidate(s), first: '
                '"${result.candidates.first.title}" '
                '[${result.candidates.first.providerLabel}, '
                '${result.candidates.first.matchKind.name}, '
                'year=${result.candidates.first.year}]';
      log.writeln('$label ($code): OK in ${elapsed.inMilliseconds}ms - $first');
    } on ProviderException catch (error) {
      final elapsed = DateTime.now().difference(started);
      log.writeln(
        '$label ($code): ${error.kind.name} after ${elapsed.inMilliseconds}ms '
        '- ${error.message}',
      );
    } on Object catch (error) {
      log.writeln('$label ($code): unexpected - $error');
    }
  }

  await run(
    'openlibrary',
    OpenLibraryProvider(
      transport: transport,
      limiter: limiters['openlibrary'],
      clock: clock,
    ),
    '9780306406157',
  );
  await run(
    'musicbrainz',
    MusicBrainzProvider(
      transport: transport,
      limiter: limiters['musicbrainz'],
      clock: clock,
    ),
    '0724384654726',
  );
  await run(
    'upcitemdb',
    UpcItemDbProvider(
      transport: transport,
      limiter: limiters['upcitemdb'],
      clock: clock,
    ),
    '5051892202657',
  );

  final file = File('docs/agent-work/lyberry/evidence/p2/live-smoke.log');
  await file.writeAsString(log.toString(), mode: FileMode.append);
  stdout.write(log.toString());
}
