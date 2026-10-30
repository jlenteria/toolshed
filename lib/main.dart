import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'tools/registry.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      final registry = ToolRegistry.instance;
      runApp(ToolshedApp(registry: registry));
      // Started here rather than in initState so the shell paints immediately
      // even when plutil, launchctl or a usage-stats query is being slow.
      unawaited(registry.refresh());
    },
    (error, stack) {
      debugPrint('toolshed: $error\n$stack');
    },
  );
}
