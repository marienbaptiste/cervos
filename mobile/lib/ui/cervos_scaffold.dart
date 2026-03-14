import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/constants.dart';

/// Common dark scaffold with Level 0 background and Level 1 app bar.
class CervosScaffold extends StatelessWidget {
  const CervosScaffold({
    super.key,
    required this.body,
    this.title = 'cervos',
    this.actions,
  });

  final Widget body;
  final String title;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CervosTheme.level0,
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 20,
          ),
        ),
        actions: actions,
      ),
      body: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: body,
      ),
    );
  }
}
