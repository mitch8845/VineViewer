import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_theme.dart';
import 'features/projects/project_list_screen.dart';

void main() {
  runApp(const ProviderScope(child: VineViewerApp()));
}

class VineViewerApp extends StatelessWidget {
  const VineViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VineViewer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // Light unless the tablet itself is set to dark: a vineyard at noon is
      // the normal case, and a light UI reads better in sun.
      themeMode: ThemeMode.system,
      home: const ProjectListScreen(),
    );
  }
}
