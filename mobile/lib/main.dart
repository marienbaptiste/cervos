import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: CervosApp()));
}

class CervosApp extends StatelessWidget {
  const CervosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cervos',
      theme: CervosTheme.darkTheme,
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
