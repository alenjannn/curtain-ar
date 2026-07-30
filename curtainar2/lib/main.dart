import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

/// Simply Curtains brand navy.
const Color kBrandNavy = Color(0xFF2C3E50);

void main() {
  runApp(const SimplyCurtainsApp());
}

class SimplyCurtainsApp extends StatelessWidget {
  const SimplyCurtainsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Simply Curtains AR',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kBrandNavy,
          primary: kBrandNavy,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kBrandNavy,
          foregroundColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: kBrandNavy,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
            textStyle:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
