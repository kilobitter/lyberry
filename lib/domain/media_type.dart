/// The six physical media families Lyberry tracks.
///
/// [wireValue] is the stable serialized form used by storage and by the phase 2
/// backup format. Never change an existing value.
enum MediaType {
  book('book', 'Book', 'Books'),
  cd('cd', 'CD', 'CDs'),
  dvd('dvd', 'DVD', 'DVDs'),
  bluray('bluray', 'Blu-ray', 'Blu-ray'),
  vinyl('vinyl', 'Vinyl', 'Vinyl'),
  game('game', 'Game', 'Games');

  const MediaType(this.wireValue, this.label, this.pluralLabel);

  final String wireValue;
  final String label;
  final String pluralLabel;

  static MediaType? tryParse(Object? value) {
    if (value is! String) return null;
    for (final type in MediaType.values) {
      if (type.wireValue == value) return type;
    }
    return null;
  }

  static MediaType parse(Object? value) {
    final parsed = tryParse(value);
    if (parsed == null) {
      throw FormatException('Unknown media type: $value');
    }
    return parsed;
  }

  /// Media types whose editors expose a platform field.
  bool get hasPlatform => this == MediaType.game;

  /// Media types whose copies can be marked as finished.
  ///
  /// Only books and films (DVD/Blu-ray) have a meaningful "finished" state;
  /// every other family keeps the flag hidden while still storing it.
  bool get isFinishable =>
      this == MediaType.book ||
      this == MediaType.dvd ||
      this == MediaType.bluray;
}
