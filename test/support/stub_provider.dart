import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';

/// Deterministic provider for widget and golden tests.
class StubMetadataProvider implements MetadataProvider {
  StubMetadataProvider({
    this.id = 'stub',
    this.label = 'Stub Source',
    this.candidates = const <MetadataCandidate>[],
    this.failure,
    this.mediaTypes = const <MediaType>{},
    this.roles = const <ProviderRole>{},
  });

  @override
  final String id;

  @override
  final String label;

  final List<MetadataCandidate> candidates;
  final ProviderException? failure;
  final Set<MediaType> mediaTypes;

  @override
  final Set<ProviderRole> roles;

  int calls = 0;

  @override
  bool supports(MediaType? mediumHint) =>
      mediaTypes.isEmpty ||
      mediumHint == null ||
      mediaTypes.contains(mediumHint);

  @override
  Future<ProviderLookupResult> lookup(LookupQuery query) async {
    calls++;
    final problem = failure;
    if (problem != null) throw problem;
    return ProviderLookupResult(candidates: candidates);
  }
}

MetadataCandidate stubCandidate({
  String providerId = 'stub',
  String providerLabel = 'Stub Source',
  String externalId = 'record-1',
  MatchKind matchKind = MatchKind.exact,
  String title = 'Dune',
  String creator = 'Frank Herbert',
  int? year = 1974,
  String publisher = 'Chilton',
  MediaType? medium = MediaType.book,
  String description = '',
  String? coverUrl,
  String? sourceUrl = 'https://example.invalid/record-1',
}) => MetadataCandidate(
  providerId: providerId,
  providerLabel: providerLabel,
  externalId: externalId,
  matchKind: matchKind,
  title: title,
  creator: creator,
  year: year,
  publisher: publisher,
  medium: medium,
  description: description,
  coverUrl: coverUrl,
  sourceUrl: sourceUrl,
);
