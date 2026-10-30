import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/console_parts.dart';
import '../widgets/status_style.dart';

/// Where users can support the project straight from their wallet.
///
/// The QR is [qrAsset], opened from the dashboard's menu. Nothing here asks
/// for an account, and the payment happens in the user's own bank app.
class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  static const qrAsset = 'docs/banks/bpi.jpg';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Support toolshed')),
      body: ContentColumn(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Center(
              child: IconBadge(
                icon: Icons.favorite_border,
                color: theme.colorScheme.tertiary,
                size: 64,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'toolshed is free, with no ads and no accounts. Every tool and '
              'every capability is available to everyone. If you would like '
              'to, you can send an optional, voluntary tip directly to the '
              'developer. It unlocks nothing and gives no rewards.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 22),
            SectionCard(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.asset(
                      qrAsset,
                      width: 260,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Scan with any QR Ph app. This is a direct person-to-person '
                  'transfer to the developer, not a purchase.',
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Never required. Thank you for using toolshed!',
              textAlign: TextAlign.center,
              style: text.labelMedium?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
