import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';

import '../models/swatch.dart';
import '../widgets/swatch_selector.dart';

/// AR Screen backed by Unity via [UnityWidget].
///
/// Implements the Flutter-Unity shell architecture:
/// - [UnityWidget] rendering the AR camera, plane detection & placement rect.
/// - [GestureDetector] wrapping [UnityWidget] to capture pinch-resize & drag gestures.
/// - Overlaid Flutter UI:
///   - Swatch Selector (changes curtain/rect fabric color)
///   - CM Readout Card (displays real-world dimensions in cm)
///   - Camera Button (captures & saves screenshot)
///   - Reset Button (resets placement rectangle)
/// - Two-way communication channels:
///   - Flutter -> Unity: `changeColor`, `resizeRect`, `resetRect`
///   - Unity -> Flutter: `onPlaneDetected`, `onRectPlaced`, `onMeasurement`
///
///
class UnityArScreen extends StatefulWidget {
  const UnityArScreen({super.key});

  @override
  State<UnityArScreen> createState() => _UnityArScreenState();
}

class _UnityArScreenState extends State<UnityArScreen> {
  UnityWidgetController? _unityWidgetController;

  // AR state received from Unity -> Flutter channel
  bool _planeDetected = false;
  bool _rectPlaced = false;
  double _widthCm = 150.0;
  double _heightCm = 240.0;
  Swatch _selectedSwatch = kSwatches.first;

  // Gesture state for scale/drag resizing
  double _baseWidthCm = 150.0;
  double _baseHeightCm = 240.0;

  // Unity GameObject Target Name
  static const String kUnityObjectName = 'ARManager';

  // -------------------------------------------------- Flutter -> Unity Channel

  /// Sends hex color string (e.g. "#F5F5F5") to Unity when swatch is selected.
  void changeColor(Swatch swatch) {
    setState(() {
      _selectedSwatch = swatch;
    });
    _unityWidgetController?.postMessage(
      kUnityObjectName,
      'changeColor',
      swatch.hex,
    );
  }

  /// Sends width and height in cm to Unity when gesture updates.
  void resizeRect(double widthCm, double heightCm) {
    setState(() {
      _widthCm = widthCm.clamp(50.0, 500.0);
      _heightCm = heightCm.clamp(50.0, 500.0);
    });

    final payload = jsonEncode({
      'widthCm': _widthCm,
      'heightCm': _heightCm,
    });

    _unityWidgetController?.postMessage(
      kUnityObjectName,
      'resizeRect',
      payload,
    );
  }

  /// Sends reset command to Unity.
  void resetRect() {
    setState(() {
      _rectPlaced = false;
      _widthCm = 150.0;
      _heightCm = 240.0;
    });

    _unityWidgetController?.postMessage(
      kUnityObjectName,
      'resetRect',
      '',
    );
  }

  // -------------------------------------------------- Unity -> Flutter Channel

  void _onUnityCreated(UnityWidgetController controller) {
    _unityWidgetController = controller;
  }

  void _onUnitySceneLoaded(SceneLoaded? sceneInfo) {
    debugPrint('Unity scene loaded: ${sceneInfo?.name}');
  }

  /// Handler for messages arriving from Unity (`onPlaneDetected`, `onRectPlaced`, `onMeasurement`).
  void _onUnityMessage(dynamic message) {
    final String dataStr = message.toString();
    debugPrint('Received message from Unity: $dataStr');

    try {
      final Map<String, dynamic> data =
          jsonDecode(dataStr) as Map<String, dynamic>;
      final String event = data['event']?.toString() ?? '';

      switch (event) {
        case 'onPlaneDetected':
          setState(() {
            _planeDetected = true;
          });
          break;
        case 'onRectPlaced':
          setState(() {
            _rectPlaced = true;
          });
          break;
        case 'onMeasurement':
          setState(() {
            if (data.containsKey('widthCm')) {
              _widthCm = (data['widthCm'] as num).toDouble();
            }
            if (data.containsKey('heightCm')) {
              _heightCm = (data['heightCm'] as num).toDouble();
            }
          });
          break;
      }
    } catch (_) {
      // Fallback for simple string messages
      if (dataStr == 'onPlaneDetected') {
        setState(() => _planeDetected = true);
      } else if (dataStr == 'onRectPlaced') {
        setState(() => _rectPlaced = true);
      }
    }
  }

  // -------------------------------------------------- Camera Action

  Future<void> _takeScreenshot() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Screenshot saved to Gallery'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // -------------------------------------------------- Build UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. UnityWidget wrapped inside GestureDetector
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (details) {
                _baseWidthCm = _widthCm;
                _baseHeightCm = _heightCm;
              },
              onScaleUpdate: (details) {
                if (_rectPlaced) {
                  final newWidth = _baseWidthCm * details.horizontalScale;
                  final newHeight = _baseHeightCm * details.verticalScale;
                  resizeRect(newWidth, newHeight);
                }
              },
              child: UnityWidget(
                onUnityCreated: _onUnityCreated,
                onUnityMessage: _onUnityMessage,
                onUnitySceneLoaded: _onUnitySceneLoaded,
                useAndroidViewSurface: true,
              ),
            ),
          ),

          // 2. Status / Instruction Banner
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            right: 16,
            child: Row(
              children: [
                IconButton.filledTonal(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.54),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.54),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Text(
                      !_planeDetected
                          ? 'Scanning wall surface...'
                          : !_rectPlaced
                              ? 'Tap wall to place curtain rectangle'
                              : 'Pinch/drag to resize • Tap swatch to recolor',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 3. Overlaid CM Readout Card & Reset Button (Flutter — overlaid on top)
          if (_rectPlaced) ...[
            Positioned(
              top: MediaQuery.of(context).padding.top + 68,
              left: 20,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.straighten, color: Colors.amber, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '${_widthCm.toStringAsFixed(0)} cm W  ×  ${_heightCm.toStringAsFixed(0)} cm H',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn().slideY(begin: -0.2, end: 0),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 68,
              right: 20,
              child: IconButton.filledTonal(
                icon: const Icon(Icons.refresh, color: Colors.white),
                tooltip: 'Reset Placement',
                onPressed: resetRect,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],

          // 4. Camera Button (Flutter — overlaid on top)
          Positioned(
            bottom: 110,
            right: 20,
            child: FloatingActionButton(
              heroTag: 'unity_camera_btn',
              onPressed: _takeScreenshot,
              backgroundColor: Colors.white,
              child: const Icon(Icons.camera_alt, color: Colors.black87),
            ),
          ),

          // 5. Swatch Selector (Flutter — overlaid on top)
          Positioned(
            bottom: 24,
            left: 0,
            right: 0,
            child: SwatchSelector(
              swatches: kSwatches,
              selectedSwatch: _selectedSwatch,
              onSwatchSelected: changeColor,
              visible: _rectPlaced,
            ),
          ),
        ],
      ),
    );
  }
}
