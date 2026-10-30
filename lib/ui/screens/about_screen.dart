import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../theme.dart';
import '../widgets/console_parts.dart';

/// What this app is, what it reads, and what it never sends anywhere.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('About toolshed')),
      body: ContentColumn(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Center(
              child: Image.asset('assets/logo.png', width: 76, height: 76),
            ),
            const SizedBox(height: 14),
            Text(
              'toolshed',
              textAlign: TextAlign.center,
              style: text.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Version $appVersion · $_platform',
              textAlign: TextAlign.center,
              style: text.labelMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 20),
            Text(
              'A cross-platform developer console for the machines you are '
              'sitting at, from one Flutter codebase.',
              textAlign: TextAlign.center,
              style: text.bodyMedium,
            ),
            const SizedBox(height: 14),
            const SectionCard(
              children: [
                SectionLabel('This build'),
                FactRow(
                  icon: Icons.verified_outlined,
                  text:
                      'No third-party packages: every read is dart:io or a '
                      'platform channel, so nothing drifts upstream.',
                ),
                FactRow(
                  icon: Icons.lock_outline,
                  text:
                      'Nothing is sent off this machine — no telemetry, no '
                      'analytics, no account.',
                ),
                FactRow(
                  icon: Icons.devices_outlined,
                  text:
                      'macOS, Linux, Windows and Android, with each tool '
                      'stating what it can actually do on that device.',
                ),
              ],
            ),
            const SizedBox(height: 14),
            const InlineNote(
              icon: Icons.shield_outlined,
              text:
                  'Zero data collection. Helpers run as your own user, the '
                  'root fan daemon only speaks over a local socket, and no '
                  'read is ever uploaded.',
            ),
            const SizedBox(height: 18),
            Text(
              'A disabled button always says why, in the same screen, because '
              'a console that guesses at your platform is worse than one that '
              'admits it.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }

  String get _platform => switch (Platform.operatingSystem) {
    'macos' => 'macOS',
    'linux' => 'Linux',
    'windows' => 'Windows',
    'android' => 'Android',
    final other => other,
  };
}
