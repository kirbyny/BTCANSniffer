import 'package:flutter/material.dart';

import 'home_screen.dart';

void main() {
  runApp(const BtCanApp());
}

class BtCanApp extends StatelessWidget {
  const BtCanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BTCAN Viewer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A8A5A)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
