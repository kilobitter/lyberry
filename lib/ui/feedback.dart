import 'package:flutter/material.dart';

/// Shows one short message; used for every user-visible failure and outcome.
void showMessage(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: action,
        duration: const Duration(seconds: 4),
      ),
    );
}
