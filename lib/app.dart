import 'package:flutter/material.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/library_scope.dart';
import 'package:lyberry/ui/navigation.dart';
import 'package:lyberry/ui/screens/home_screen.dart';
import 'package:lyberry/ui/screens/settings_screen.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/bottom_bar.dart';

class LyberryApp extends StatelessWidget {
  const LyberryApp({
    super.key,
    required this.controller,
    required this.services,
  });

  final LibraryController controller;
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return LibraryScope(
      controller: controller,
      child: AppServicesScope(
        services: services,
        child: MaterialApp(
          title: 'Lyberry',
          debugShowCheckedModeBanner: false,
          theme: buildLyberryTheme(),
          home: const AppShell(),
        ),
      ),
    );
  }
}

/// Library and Settings tabs with the scan action between them.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _startRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_startRequested) return;
    _startRequested = true;
    final controller = LibraryScope.of(context);
    // Opening the store can notify listeners immediately; defer past this build.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.start());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const <Widget>[HomeScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: LyberryBottomBar(
        selectedIndex: _index,
        onSelect: (index) => setState(() => _index = index),
        onScan: () => openScan(context),
      ),
    );
  }
}
