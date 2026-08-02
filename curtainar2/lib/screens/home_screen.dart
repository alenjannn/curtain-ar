import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'ar_screen.dart';
import 'unity_ar_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _launchArPreview(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ArScreen()),
    );
  }

  void _launchUnityArPreview(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const UnityArScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Simply Curtains AR',
                  textAlign: TextAlign.center,
                  style: textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'AR Feasibility Prototype',
                  textAlign: TextAlign.center,
                  style: textTheme.titleMedium?.copyWith(
                    color: Colors.black54,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 48),
                ElevatedButton(
                  onPressed: () => _launchArPreview(context),
                  child: const Text('Launch AR Preview'),
                ),

                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => _launchUnityArPreview(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                    side: BorderSide(color: primary, width: 1.5),
                  ),
                  child: const Text('Launch Unity AR Preview'),
                ),
              ],
            ).animate().fadeIn(duration: 700.ms, curve: Curves.easeOut).slideY(
                  begin: 0.08,
                  end: 0,
                  duration: 700.ms,
                  curve: Curves.easeOut,
                ),
          ),
        ),
      ),
    );
  }
}

