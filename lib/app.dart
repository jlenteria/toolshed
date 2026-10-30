import 'package:flutter/material.dart';

import 'tools/registry.dart';
import 'ui/screens/tools_screen.dart';
import 'ui/theme.dart';

class ToolshedApp extends StatelessWidget {
  const ToolshedApp({super.key, required this.registry});

  final ToolRegistry registry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'toolshed',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.of(Brightness.light),
      darkTheme: AppTheme.of(Brightness.dark),
      home: ToolsScreen(registry: registry),
    );
  }
}
