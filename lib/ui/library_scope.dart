import 'package:flutter/material.dart';
import 'package:lyberry/state/library_controller.dart';

/// Makes the single [LibraryController] available to the widget tree.
class LibraryScope extends InheritedNotifier<LibraryController> {
  const LibraryScope({
    super.key,
    required LibraryController controller,
    required super.child,
  }) : super(notifier: controller);

  static LibraryController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LibraryScope>();
    assert(scope != null, 'LibraryScope is missing above this widget.');
    return scope!.notifier!;
  }
}
