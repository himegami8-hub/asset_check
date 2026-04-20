import 'package:flutter/material.dart';
import 'package:asset_check/screens/list_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'チェック革命',
      theme: ThemeData(useMaterial3: true),
      home: const ListScreen(),
    );
  }
}
