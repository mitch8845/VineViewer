import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/projects/project_list_screen.dart';

void main() {
  runApp(const ProviderScope(child: PlantViewerApp()));
}

class PlantViewerApp extends StatelessWidget {
  const PlantViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PlantViewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B2C6F)),
      ),
      home: const ProjectListScreen(),
    );
  }
}
