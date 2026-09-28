/// Optional real maintainer contact, supplied at build time:
/// `--dart-define=LYBERRY_CONTACT=you@example.org`.
///
/// MusicBrainz asks for an identifying agent; Lyberry never invents an address.
const String lyberryContact = String.fromEnvironment('LYBERRY_CONTACT');

String lyberryUserAgent({String contact = lyberryContact}) {
  final trimmed = contact.trim();
  return trimmed.isEmpty
      ? 'Lyberry/0.3 (personal media collection app)'
      : 'Lyberry/0.3 ($trimmed)';
}

bool get hasPublishedContact => lyberryContact.trim().isNotEmpty;
