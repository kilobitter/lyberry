import 'package:flutter/material.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/state/item_draft.dart';
import 'package:lyberry/state/web_lookup_controller.dart';
import 'package:lyberry/ui/screens/candidates_screen.dart';
import 'package:lyberry/ui/screens/detail_screen.dart';
import 'package:lyberry/ui/screens/editor_screen.dart';
import 'package:lyberry/ui/screens/scan_screen.dart';
import 'package:lyberry/ui/screens/settings_screen.dart';
import 'package:lyberry/ui/screens/web_lookup_screen.dart';

Future<void> openDetail(BuildContext context, String itemId) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => DetailScreen(itemId: itemId)),
  );
}

/// Opens the editor for [existing], or a blank copy when it is `null`.
Future<void> openEditor(
  BuildContext context, {
  MediaItem? existing,
  ItemDraft? prefill,
  String? coverUrl,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => EditorScreen(
        existing: existing,
        prefill: prefill,
        coverUrl: coverUrl,
      ),
    ),
  );
}

Future<void> openScan(BuildContext context) {
  return Navigator.of(
    context,
  ).push<void>(MaterialPageRoute<void>(builder: (_) => const ScanScreen()));
}

/// Opens the explicit web lookup for [identifier]. Returns the user's choice,
/// or `null` when they backed out.
Future<LookupChoice?> openWebLookup(
  BuildContext context, {
  required NormalizedIdentifier identifier,
  MediaType? mediumHint,
  WebLookupMode mode = WebLookupMode.search,
}) {
  return Navigator.of(context).push<LookupChoice>(
    MaterialPageRoute<LookupChoice>(
      builder: (_) => WebLookupScreen(
        identifier: identifier,
        mediumHint: mediumHint,
        initialMode: mode,
      ),
    ),
  );
}

/// Settings as a pushed route, so a screen that needs a key can send the user
/// there and come back with the code still on screen.
Future<void> openSettings(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const SettingsRouteScreen()),
  );
}
