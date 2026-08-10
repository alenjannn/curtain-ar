import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_unity_widget_2/flutter_unity_widget_2.dart';
import 'package:gal/gal.dart';

import '../models/swatch.dart';
import '../widgets/swatch_selector.dart';

// ------------------------------------------------------------------ bridging

/// The GameObject `postMessage` addresses.
///
/// `UnitySendMessage` — what `postMessage` calls under the hood — resolves a **GameObject by
/// name**, not a component by type. The scene builder creates an object with exactly this name
/// carrying `FlutterBridge` (see `CurtainARSceneBuilder.CreateScene`); renaming either side
/// silently drops every message, because `UnitySendMessage` fails quietly.
const String kUnityObjectName = 'ARPlacementController';

/// Unity's `ARPlacementController.m_DefaultWidthCm` / `m_DefaultHeightCm`. Only used until the
/// first `rectPlaced` arrives — after that Unity is the source of truth for the readout.
const double _kDefaultWidthCm = 80;
const double _kDefaultHeightCm = 180;

const double _kMinWidthCm = 30;
const double _kMaxWidthCm = 250;
const double _kMinHeightCm = 50;
const double _kMaxHeightCm = 350;

/// How far the panel may slide along the wall from where it was tapped, either way.
const double _kMaxOffsetCm = 150;

const double _kHeightCmPerPixel = 0.5;
const double _kOffsetCmPerPixel = 0.3;

/// Travel before a one-finger drag commits to an axis. Below this the drag is ambiguous and
/// nothing moves, so a slightly diagonal drag cannot flip between resizing and repositioning.
const double _kAxisLockSlopPx = 10;

/// Minimum gap between gesture-driven `postMessage` calls. Every one is a platform-channel round
/// trip into the Unity player; at vsync rate that saturates the channel and the panel starts
/// lagging the finger. ~30 Hz is indistinguishable and costs a third as much.
const Duration _kUnityWriteInterval = Duration(milliseconds: 32);

/// Unity renders the capture at end-of-frame and writes a PNG, so a reply is not instant — but
/// silence past this means the message never reached the bridge.
const Duration _kScreenshotTimeout = Duration(seconds: 8);

/// How long the platform view may exist without Unity reporting a loaded scene before the screen
/// calls it: see [_armHandshakeWatchdog]. The first debug launch may need to extract IL2CPP data
/// before the scene can load, which can take more than 12 seconds on a physical device.
const Duration _kUnityHandshakeTimeout = Duration(seconds: 30);

// ---------------------------------------------------------------------- ui

const Duration _kShutterFlashDuration = Duration(milliseconds: 150);
const Duration _kThumbnailDuration = Duration(seconds: 4);
const double _kThumbnailSize = 72;

const Duration _kInstructionOverlayDuration = Duration(seconds: 4);

const Color _kPanelColor = Color(0xD90A1A33);

/// Which property a one-finger drag is adjusting. Locked in once the drag clears
/// [_kAxisLockSlopPx] and held until the finger lifts.
enum _GestureAxis { height, position, width }

/// AR screen backed by Unity (AR Foundation) via [UnityWidget].
///
/// Unity owns the camera feed, plane detection and the placed panel. Every piece of UI is a
/// Flutter widget stacked on top of the platform view, and the two halves talk over the
/// flutter_unity_widget bridge:
///
/// * Flutter → Unity, via [_sendToUnity]: `OnTap`, `ChangeColor`, `ResizeRect`,
///   `RepositionRect`, `ResetRect`, `CaptureScreenshot`.
/// * Unity → Flutter, via [_onUnityMessage]: `planeDetected`, `rectPlaced`, `measurement`,
///   `screenshot`, `screenshotFailed` — each wrapped as `{"event": ..., "data": {...}}`.
///
/// Unity's own touch handling is switched off by `FlutterBridge.Awake`, because Flutter owns the
/// gesture arena while Unity is embedded in a platform view. Taps only reach placement if this
/// screen forwards them.
class UnityArScreen extends StatefulWidget {
  const UnityArScreen({super.key});

  @override
  State<UnityArScreen> createState() => _UnityArScreenState();
}

class _UnityArScreenState extends State<UnityArScreen> {
  UnityWidgetController? _unityController;

  /// True once the player exists and [_unityController] can be posted to. Messages sent before
  /// this are dropped on the floor by the plugin.
  bool _unityReady = false;

  bool _planeDetected = false;
  bool _rectPlaced = false;

  double _widthCm = _kDefaultWidthCm;
  double _heightCm = _kDefaultHeightCm;
  double _offsetXCm = 0;

  Swatch _selectedSwatch = kSwatches.first;

  /// Built once so the platform view subtree is never rebuilt or diffed. `Element.updateChild`
  /// short-circuits on an identical widget instance, which keeps a 30 Hz gesture stream from
  /// re-creating the Unity surface.
  late final Widget _unitySurface;

  // --------------------------------------------------------------- gestures

  /// Snapshot taken when a gesture begins. Every update is computed from this rather than
  /// accumulated, so clamping is reversible — drag back out of a limit and the panel follows
  /// instead of sticking.
  double _gestureStartWidthCm = _kDefaultWidthCm;
  double _gestureStartHeightCm = _kDefaultHeightCm;
  double _gestureStartOffsetCm = 0;

  Offset _gestureStartFocal = Offset.zero;

  /// Focal point at the moment the axis locked, so the [_kAxisLockSlopPx] dead zone is not also
  /// applied as a jump.
  Offset _axisAnchorFocal = Offset.zero;

  _GestureAxis? _axis;
  bool _gestureActive = false;

  final Stopwatch _gestureClock = Stopwatch()..start();
  Duration _lastUnityWrite = Duration.zero;

  // ------------------------------------------------------------- screenshot

  bool _isCapturing = false;
  bool _shutterFlash = false;
  Uint8List? _thumbnail;
  Timer? _thumbnailTimer;
  Timer? _screenshotTimeout;

  bool _showInstructions = false;
  bool _instructionsShown = false;
  Timer? _instructionTimer;

  // ------------------------------------------------------- liveness check

  /// True once Unity has reported a loaded scene — the first thing a running player does.
  bool _sceneLoaded = false;

  /// Set when [_kUnityHandshakeTimeout] elapses with no scene. See [_armHandshakeWatchdog].
  bool _unityUnreachable = false;

  Timer? _handshakeWatchdog;

  @override
  void initState() {
    super.initState();

    // Layered deliberately: the GestureDetector sits between the platform view and the rest of
    // the tree so it wins the arena before Unity's surface can claim a touch. Only the scale
    // callbacks are used for drags — Flutter rejects a pan recognizer alongside a scale one, and
    // ScaleGestureRecognizer already reports one-finger drags through focalPoint.
    _unitySurface = RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _onTapUp,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: UnityWidget(
          onUnityCreated: _onUnityCreated,
          onUnityMessage: _onUnityMessage,
          onUnitySceneLoaded: _onUnitySceneLoaded,
          fullscreen: false,
          // Hybrid composition. Without it the Unity surface is composited in its own window and
          // every Flutter overlay below is drawn *behind* the camera feed.
          useAndroidViewSurface: true,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _thumbnailTimer?.cancel();
    _screenshotTimeout?.cancel();
    _instructionTimer?.cancel();
    _handshakeWatchdog?.cancel();
    // The player keeps rendering — and holding the camera — after this route is popped, so it
    // has to be stopped explicitly.
    _unityController?.pause();
    super.dispose();
  }

  // -------------------------------------------------- Flutter → Unity channel

  /// The single Flutter → Unity exit point.
  void _sendToUnity(String method, Map<String, dynamic> data) {
    _unityController?.postMessage(
      kUnityObjectName, // Unity GameObject name
      method, // Unity method name
      jsonEncode(data), // JSON payload
    );
  }

  void _changeColor(Swatch swatch) {
    setState(() => _selectedSwatch = swatch);

    // `Swatch.hex` is already the `#RRGGBB` form Unity's ColorUtility parses — it drops the
    // alpha byte off the ARGB word and uppercases, which is what the palette is authored in.
    _sendToUnity('ChangeColor', {'hex': swatch.hex});
    debugPrint('FLUTTER → COLOR SENT: ${swatch.hex}');
  }

  void _resetRect() {
    setState(() {
      _widthCm = _kDefaultWidthCm;
      _heightCm = _kDefaultHeightCm;
      _offsetXCm = 0;
      _selectedSwatch = kSwatches.first;
    });
    _sendToUnity('ResetRect', const <String, dynamic>{});
    debugPrint('FLUTTER → ResetRect');
  }

  /// Pushes the current size/offset to Unity, throttled to [_kUnityWriteInterval].
  ///
  /// [force] bypasses the throttle, which the end of a gesture must do — otherwise the final
  /// frame of a drag is the one that gets dropped and the panel settles a few centimetres off
  /// what the readout says.
  void _flushToUnity(_GestureAxis axis, {bool force = false}) {
    final now = _gestureClock.elapsed;
    if (!force && now - _lastUnityWrite < _kUnityWriteInterval) return;
    _lastUnityWrite = now;

    switch (axis) {
      case _GestureAxis.width:
      case _GestureAxis.height:
        _sendToUnity('ResizeRect', {'widthCm': _widthCm, 'heightCm': _heightCm});
      case _GestureAxis.position:
        _sendToUnity('RepositionRect', {'offsetX': _offsetXCm / 100});
    }
  }

  // -------------------------------------------------- Unity → Flutter channel

  void _onUnityCreated(UnityWidgetController controller) {
    _unityController = controller;
    debugPrint('UNITY READY → controller attached');
    if (!mounted) return;
    setState(() => _unityReady = true);
    _armHandshakeWatchdog();
  }

  void _onUnitySceneLoaded(SceneLoaded? scene) {
    debugPrint('UNITY SCENE → ${scene?.name ?? 'unknown'} loaded');
    _handshakeWatchdog?.cancel();
    _handshakeWatchdog = null;
    if (!mounted || _sceneLoaded) return;
    setState(() {
      _sceneLoaded = true;
      _unityUnreachable = false;
    });
  }

  /// Guards against a platform view that comes up without a Unity player behind it.
  ///
  /// `onUnityCreated` fires as soon as the Android view is constructed, which happens even when
  /// `android/unityLibrary` is the placeholder stub — so a green "Unity ●" badge is not evidence
  /// that anything is running. A loaded scene is: it is the first thing a real player reports,
  /// and the stub can never produce one. Without this the screen sits on "Initializing AR..."
  /// forever and looks like a hang rather than a missing export.
  void _armHandshakeWatchdog() {
    _handshakeWatchdog?.cancel();
    _handshakeWatchdog = Timer(_kUnityHandshakeTimeout, () {
      if (!mounted || _sceneLoaded) return;
      debugPrint(
        'UNITY → no scene after ${_kUnityHandshakeTimeout.inSeconds}s — the player is not '
        'running. Is android/unityLibrary still the placeholder?',
      );
      setState(() => _unityUnreachable = true);
    });
  }

  /// Handles `{"event": "...", "data": {...}}` coming back over the bridge.
  ///
  /// The callback is `void Function(dynamic)` in flutter_unity_widget 2022.2.1 — it does not
  /// hand back the controller — and [message] is the raw string Unity emitted.
  void _onUnityMessage(dynamic message) {
    final raw = message?.toString() ?? '';
    debugPrint('UNITY → $raw');

    final Map<String, dynamic> envelope;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      envelope = decoded;
    } catch (_) {
      // Anything that is not our envelope is Unity-internal chatter (the bridge's own
      // "@UnityMessage@" traffic, for one) and is not this screen's business.
      return;
    }

    final event = envelope['event']?.toString();
    final data = envelope['data'] is Map<String, dynamic>
        ? envelope['data'] as Map<String, dynamic>
        : const <String, dynamic>{};

    switch (event) {
      case 'planeDetected':
        if (_planeDetected || !mounted) return;
        debugPrint('UNITY → plane detected (${data['type'] ?? 'unknown'})');
        setState(() => _planeDetected = true);

      case 'rectPlaced':
        debugPrint('UNITY → rect placed');
        if (!mounted) return;
        setState(() {
          _rectPlaced = true;
          _offsetXCm = 0;
          _widthCm = _readCm(data['widthCm'], _widthCm);
          _heightCm = _readCm(data['heightCm'], _heightCm);
        });
        // Placement is what unlocks the palette, so re-apply the chosen swatch: Unity resets the
        // panel to white every time it is placed.
        if (_selectedSwatch != kSwatches.first) {
          _sendToUnity('ChangeColor', {'hex': _selectedSwatch.hex});
        }
        _showInstructionsOnce();

      case 'measurement':
        // Echoed straight back from our own ResizeRect. Applying it mid-gesture would let a
        // late reply snap the readout back over a newer local value.
        if (_gestureActive || !mounted) return;
        setState(() {
          _widthCm = _readCm(data['widthCm'], _widthCm);
          _heightCm = _readCm(data['heightCm'], _heightCm);
        });

      case 'colorApplied':
        final hex = data['hex']?.toString() ?? '';
        debugPrint('UNITY → confirmed color: $hex');
        // The selector already moved its highlight optimistically on tap, so a success needs no
        // further UI work. A failure is the only case worth surfacing.
        if (data['success'] != true) {
          _showSnack('Color swap failed on this device', error: true);
        }

      case 'screenshot':
        unawaited(_saveScreenshot(data['path']?.toString()));

      case 'screenshotFailed':
        _finishCapture(
          failure: 'Unity could not capture the frame',
          detail: data['reason']?.toString(),
        );
    }
  }

  static double _readCm(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;

  // ---------------------------------------------------------------- gestures

  /// Forwards a tap to Unity's raycast. Unity's own input is disabled while embedded, so without
  /// this nothing is ever placed.
  void _onTapUp(TapUpDetails details) {
    if (!_unityReady) return;

    // Flutter's origin is top-left in logical pixels; Unity's is bottom-left in physical ones.
    // `FlutterBridge.OnTap` does the flip, but it needs the ratio to do it with.
    _sendToUnity('OnTap', {
      'x': details.localPosition.dx,
      'y': details.localPosition.dy,
      'dpr': MediaQuery.devicePixelRatioOf(context),
    });
    debugPrint(
      'FLUTTER → OnTap (${details.localPosition.dx.toStringAsFixed(0)}, '
      '${details.localPosition.dy.toStringAsFixed(0)})',
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartWidthCm = _widthCm;
    _gestureStartHeightCm = _heightCm;
    _gestureStartOffsetCm = _offsetXCm;
    _gestureStartFocal = details.localFocalPoint;
    _axisAnchorFocal = details.localFocalPoint;
    _axis = null;
    _gestureActive = true;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (!_rectPlaced) return;

    // Two fingers is unambiguous, and can take over from a one-finger axis mid-gesture.
    if (details.pointerCount >= 2) {
      if (_axis != _GestureAxis.width) {
        _axis = _GestureAxis.width;
        _gestureStartWidthCm = _widthCm;
      }
      final next =
          (_gestureStartWidthCm * details.scale).clamp(_kMinWidthCm, _kMaxWidthCm);
      if (next == _widthCm) return;
      setState(() => _widthCm = next);
      _flushToUnity(_GestureAxis.width);
      return;
    }

    if (_axis == null) {
      final travel = details.localFocalPoint - _gestureStartFocal;
      if (travel.distance < _kAxisLockSlopPx) return;

      _axis = travel.dy.abs() > travel.dx.abs()
          ? _GestureAxis.height
          : _GestureAxis.position;
      // Re-base off the point where the lock happened, so the dead zone is not also a jump.
      _axisAnchorFocal = details.localFocalPoint;
      _gestureStartHeightCm = _heightCm;
      _gestureStartOffsetCm = _offsetXCm;
    }

    final moved = details.localFocalPoint - _axisAnchorFocal;

    switch (_axis!) {
      case _GestureAxis.height:
        // Screen y grows downward, so dragging *up* is a negative dy and must make the panel
        // taller.
        final next = (_gestureStartHeightCm - moved.dy * _kHeightCmPerPixel)
            .clamp(_kMinHeightCm, _kMaxHeightCm);
        if (next == _heightCm) return;
        setState(() => _heightCm = next);
        _flushToUnity(_GestureAxis.height);

      case _GestureAxis.position:
        final next = (_gestureStartOffsetCm + moved.dx * _kOffsetCmPerPixel)
            .clamp(-_kMaxOffsetCm, _kMaxOffsetCm);
        if (next == _offsetXCm) return;
        setState(() => _offsetXCm = next);
        _flushToUnity(_GestureAxis.position);

      case _GestureAxis.width:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final axis = _axis;
    _axis = null;
    _gestureActive = false;
    if (axis == null || !_rectPlaced) return;

    // The throttle drops whatever landed inside the last 32 ms, which is exactly the frame that
    // decides where the panel ends up.
    _flushToUnity(axis, force: true);
    HapticFeedback.selectionClick();
  }

  void _showInstructionsOnce() {
    if (_instructionsShown) return;
    _instructionsShown = true;
    setState(() => _showInstructions = true);
    _instructionTimer?.cancel();
    _instructionTimer = Timer(_kInstructionOverlayDuration, () {
      if (mounted) setState(() => _showInstructions = false);
    });
  }

  // -------------------------------------------------------------- screenshot

  /// Asks Unity for the frame. The capture itself has to happen on the Unity side — the camera
  /// feed and the panel live in a native surface that Flutter's own `RepaintBoundary` capture
  /// reads back as a transparent hole.
  Future<void> _captureScreenshot() async {
    if (_isCapturing || !_unityReady) return;
    setState(() => _isCapturing = true);

    // Flash first so the shutter feels immediate, and let it paint before the round trip.
    setState(() => _shutterFlash = true);
    await Future<void>.delayed(_kShutterFlashDuration);
    if (!mounted) return;
    setState(() => _shutterFlash = false);

    _sendToUnity('CaptureScreenshot', const <String, dynamic>{});

    _screenshotTimeout?.cancel();
    _screenshotTimeout = Timer(_kScreenshotTimeout, () {
      _finishCapture(failure: 'Screenshot timed out — Unity did not reply');
    });
  }

  Future<void> _saveScreenshot(String? path) async {
    if (path == null || path.isEmpty) {
      _finishCapture(failure: 'Unity returned no screenshot path');
      return;
    }

    try {
      final file = File(path);
      if (!await file.exists()) {
        _finishCapture(failure: 'Screenshot file was not written');
        return;
      }

      final bytes = await file.readAsBytes();
      await Gal.putImageBytes(bytes, album: 'Simply Curtains AR');
      debugPrint('SCREENSHOT → saved ${bytes.length} bytes from $path');

      // Unity wrote it to the cache directory; the gallery copy is the one that matters.
      unawaited(file.delete().catchError((_) => file));

      if (!mounted) return;
      setState(() => _thumbnail = bytes);
      _thumbnailTimer?.cancel();
      _thumbnailTimer = Timer(_kThumbnailDuration, () {
        if (mounted) setState(() => _thumbnail = null);
      });

      _finishCapture();
      _showSnack('Screenshot saved ✓');
    } catch (e) {
      _finishCapture(
        failure: e is GalException
            ? 'Could not save to gallery — permission denied'
            : 'Could not save screenshot',
        detail: '$e',
      );
    }
  }

  void _finishCapture({String? failure, String? detail}) {
    _screenshotTimeout?.cancel();
    _screenshotTimeout = null;
    if (mounted && _isCapturing) setState(() => _isCapturing = false);

    if (failure == null) return;
    debugPrint('SCREENSHOT → failed: $failure${detail == null ? '' : ' ($detail)'}');
    _showSnack(failure, error: true);
  }

  void _showSnack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red.shade700 : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _unitySurface),

          // Scanning / initialising overlay. Purely informational, so it must not eat the taps
          // that place the panel.
          if (!_planeDetected)
            Positioned.fill(
              child: IgnorePointer(
                child: _ScanOverlay(
                  unityReady: _unityReady,
                  unreachable: _unityUnreachable,
                ),
              ),
            ),

          if (_shutterFlash)
            const Positioned.fill(child: ColoredBox(color: Colors.white)),

          _buildTopBar(context, topInset),

          if (_rectPlaced) ...[
            _buildMeasurementCard(topInset),
            _buildResetButton(topInset),
          ],

          if (_showInstructions)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 200,
              child: IgnorePointer(child: _GestureInstructions()),
            ),

          if (_thumbnail != null)
            Positioned(bottom: 190, right: 20, child: _Thumbnail(bytes: _thumbnail!)),

          Positioned(
            bottom: 110,
            right: 20,
            child: FloatingActionButton(
              heroTag: 'unity_camera_btn',
              onPressed: _rectPlaced && !_isCapturing ? _captureScreenshot : null,
              backgroundColor: _rectPlaced ? Colors.white : Colors.white38,
              child: _isCapturing
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Icon(Icons.camera_alt, color: Colors.black87),
            ),
          ),

          Positioned(
            bottom: 24,
            left: 0,
            right: 0,
            child: SwatchSelector(
              swatches: kSwatches,
              selectedSwatch: _selectedSwatch,
              onSwatchSelected: _changeColor,
              visible: _rectPlaced,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, double topInset) {
    return Positioned(
      top: topInset + 12,
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.54),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                _unityUnreachable
                    ? 'Unity AR failed to start'
                    : !_unityReady
                        ? 'Starting AR engine…'
                        : !_planeDetected
                            ? 'Scanning wall surface…'
                            : !_rectPlaced
                                ? 'Ready — tap the wall to place'
                                : 'Drag to resize • Pinch for width • Tap a swatch',
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
    );
  }

  Widget _buildMeasurementCard(double topInset) {
    return Positioned(
      top: topInset + 108,
      left: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _kPanelColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.straighten, color: Colors.amber, size: 18),
            const SizedBox(width: 8),
            Text(
              '${_widthCm.toStringAsFixed(0)} cm W  ×  '
              '${_heightCm.toStringAsFixed(0)} cm H',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            if (_offsetXCm.abs() >= 1) ...[
              const SizedBox(width: 10),
              Text(
                '${_offsetXCm > 0 ? '→' : '←'} ${_offsetXCm.abs().toStringAsFixed(0)} cm',
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
          ],
        ),
      ).animate().fadeIn().slideY(begin: -0.2, end: 0),
    );
  }

  Widget _buildResetButton(double topInset) {
    return Positioned(
      top: topInset + 100,
      right: 16,
      child: IconButton.filledTonal(
        icon: const Icon(Icons.refresh, color: Colors.white),
        tooltip: 'Reset placement',
        onPressed: _resetRect,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ overlays

/// Three states in one: a spinner while the Unity player is coming up, the pulsing "point at the
/// window frame" prompt once it has, and a diagnostic when it never arrives at all.
class _ScanOverlay extends StatelessWidget {
  const _ScanOverlay({required this.unityReady, required this.unreachable});

  final bool unityReady;
  final bool unreachable;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (unreachable) {
      child = const _UnityUnreachableCard();
    } else if (unityReady) {
      child = const _ScanningPrompt();
    } else {
      child = const _InitialisingPrompt();
    }

    return ColoredBox(
      color: Colors.black.withValues(alpha: unreachable ? 0.72 : 0.35),
      child: Center(child: child),
    );
  }
}

/// Shown when the platform view exists but no Unity scene ever loaded — in practice, when
/// `android/unityLibrary` is still the placeholder stub rather than a Unity export.
class _UnityUnreachableCard extends StatelessWidget {
  const _UnityUnreachableCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 28),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
      decoration: BoxDecoration(
        color: _kPanelColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.extension_off_outlined, color: Colors.amber, size: 42),
          SizedBox(height: 16),
          Text(
            'Unity AR did not start',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 12),
          Text(
            'The AR view loaded, but no Unity scene ever started — so taps, swatches and '
            'resizing have nothing to talk to.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
          ),
          SizedBox(height: 14),
          Text(
            'In the Unity Editor, open unity/CurtainAR and run\n'
            'Flutter → Export Android (Debug), then rebuild.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.amber,
              fontSize: 12.5,
              height: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InitialisingPrompt extends StatelessWidget {
  const _InitialisingPrompt();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
        ),
        SizedBox(height: 20),
        Text(
          'Initializing AR...',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _ScanningPrompt extends StatelessWidget {
  const _ScanningPrompt();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.crop_free, color: Colors.white, size: 84)
            .animate(onPlay: (c) => c.repeat(reverse: true))
            .scaleXY(
              begin: 0.9,
              end: 1.1,
              duration: 900.ms,
              curve: Curves.easeInOut,
            )
            .fade(begin: 0.55, end: 1),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: _kPanelColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Point at window frame',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Move the phone slowly across the wall',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The gesture legend, shown once after the first placement and auto-dismissed.
class _GestureInstructions extends StatelessWidget {
  const _GestureInstructions();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: _kPanelColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InstructionLine(Icons.swap_vert, 'Drag up / down — height'),
            SizedBox(height: 8),
            _InstructionLine(Icons.swap_horiz, 'Drag left / right — position'),
            SizedBox(height: 8),
            _InstructionLine(Icons.pinch, 'Pinch — width'),
          ],
        ),
      ).animate().fadeIn(duration: 300.ms).then(delay: 3200.ms).fadeOut(
            duration: 400.ms,
          ),
    );
  }
}

class _InstructionLine extends StatelessWidget {
  const _InstructionLine(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.amber, size: 18),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      ],
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _kThumbnailSize,
      height: _kThumbnailSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white70, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
    ).animate().fadeIn(duration: 200.ms).scaleXY(begin: 0.8, end: 1);
  }
}
