import 'package:flutter/material.dart';

import 'version_panel.dart';

/// Where an ordinary build lands.
///
/// Grows a preset list in a later step; today it is the app's identity, the
/// one thing a colleague must know about it (sandbox, always) and the
/// versions a bug report needs.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PayCross Demo')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: const [
        Text(
          'Sandbox only. This build talks to the PayCross TEST environment '
          'and has no way to reach production.',
        ),
        SizedBox(height: 24),
        VersionPanel(),
      ],
    ),
  );
}
