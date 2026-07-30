// Widget tests for the AR screen.
//
// The AR session itself needs real ARCore/ARKit hardware, so these tests cover
// the pure-Flutter behaviour around it: the camera permission gate, the session
// configuration we hand the plugin, the scan readout, and the frame cost of the
// overlays. Platform channels are stubbed.

import 'dart:io';
import 'dart:math' as math;

import 'package:ar_flutter_plugin_updated/widgets/ar_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import 'package:simply_curtains_ar/screens/ar_screen.dart';

/// Mirrors `PermissionStatus` ordering in permission_handler_platform_interface.
const int _kStatusDenied = 0;
const int _kStatusGranted = 1;

/// `Permission.camera` is `Permission._(1)`.
const int _kPermissionCamera = 1;

/// `PlaneDetectionConfig.vertical.index` — what the plugin maps to
/// `PlaneFindingMode.VERTICAL` on ARCore and `.vertical` on ARKit.
const int _kPlaneDetectionVertical = 2;

const MethodChannel _permissionChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');
const MethodChannel _pathProviderChannel =
    MethodChannel('plugins.flutter.io/path_provider');
const MethodChannel _sensorsMethodChannel =
    MethodChannel('dev.fluttercommunity.plus/sensors/method');
const EventChannel _gyroscopeChannel =
    EventChannel('dev.fluttercommunity.plus/sensors/gyroscope');
const EventChannel _userAccelChannel =
    EventChannel('dev.fluttercommunity.plus/sensors/user_accel');

/// A plane hit on a *wall*, serialized the way the native side sends it.
///
/// R_x(+90°) takes the pose's local +Y — which both platforms define as the
/// surface normal — onto world +Z, so the normal is horizontal and
/// `isVerticalSurface` reads true. An identity transform would instead look
/// like a floor.
final Map<String, Object> _wallHit = <String, Object>{
  'type': 1, // ARHitTestResultType.plane
  'distance': 1.0,
  'worldTransform': (List<double>.filled(16, 0)
    ..setAll(
      0,
      vm.Matrix4.compose(
        vm.Vector3(0, 0, -2),
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.pi / 2),
        vm.Vector3.all(1),
      ).storage,
    )),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  MockStreamHandlerEventSink? gyroSink;
  MockStreamHandlerEventSink? accelSink;
  final arViewChannels = <MethodChannel>[];
  final sessionCalls = <MethodCall>[];
  final objectCalls = <MethodCall>[];
  final anchorCalls = <MethodCall>[];
  String? sessionChannelName;

  // Shared across the suite: the screen's model copy is fire-and-forget, so a
  // per-test directory can still be held open when the test ends.
  final documentsDir = Directory.systemTemp.createTempSync('ar_screen_test');
  tearDownAll(() {
    try {
      documentsDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps the handle briefly; leaving a temp dir behind is fine.
    }
  });

  /// Stubs the permission channel so `Permission.camera` resolves to [status].
  /// Returns the list of method names the widget invoked.
  List<String> stubPermissions(int status) {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(_permissionChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'checkPermissionStatus':
          return status;
        case 'requestPermissions':
          return <int, int>{_kPermissionCamera: status};
        case 'openAppSettings':
          return true;
        default:
          return null;
      }
    });
    return calls;
  }

  /// Drives the AR screen to its scanning state and lets the permission future
  /// resolve. Never uses pumpAndSettle — the scan pulse repeats while scanning.
  Future<void> pumpScanningScreen(WidgetTester tester) async {
    stubPermissions(_kStatusGranted);
    await tester.pumpWidget(const MaterialApp(home: ArScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// As above, but also lets the real event loop turn so the platform view is
  /// created and the plugin's per-view channels come up. Needed by anything
  /// that inspects or drives the AR session.
  Future<void> pumpScreenWithSession(WidgetTester tester) async {
    await pumpScanningScreen(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  /// Delivers a platform → Flutter call on the AR session channel, the way the
  /// native side reports plane detection.
  Future<void> emitSessionCallback(
    WidgetTester tester,
    String method,
    Object? arguments,
  ) async {
    expect(sessionChannelName, isNotNull,
        reason: 'AR session channel was never created');
    await messenger.handlePlatformMessage(
      sessionChannelName!,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
    await tester.pump();
  }

  /// Pushes a sensor sample and lets it traverse the binary messenger. The
  /// delivery runs on the real event loop, which `testWidgets`' fake clock does
  /// not advance — hence `runAsync` rather than a plain pump.
  Future<void> emitSensor(
    WidgetTester tester,
    MockStreamHandlerEventSink? sink,
    List<double> xyz,
  ) async {
    expect(sink, isNotNull, reason: 'sensor stream was never subscribed');
    await tester.runAsync(() async {
      sink!.success(xyz);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  }

  /// Lets the fire-and-forget preload actually run: staging touches the real
  /// filesystem and the warm-up makes a platform-channel round trip, neither
  /// of which advances on the fake clock.
  Future<void> settlePreload(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  /// Drives a full placement: wall detected, then a plane hit delivered the way
  /// the native side reports one. `_placeCurtain` crosses several channel round
  /// trips, so the real event loop has to turn before the curtain is placed.
  Future<void> placeCurtain(WidgetTester tester) async {
    await settlePreload(tester);
    await emitSessionCallback(tester, 'onPlaneDetected', 1);
    await emitSessionCallback(tester, 'onPlaneOrPointTap', <Object>[_wallHit]);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    // Let the pop-in and the measurement card's entrance finish.
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The stubbed warm-up cannot compile a renderable, so every run puts the
  /// fallback snackbar on screen — and it sits over the bottom bar, where it
  /// would swallow a tap meant for Reset or Next. Waits it out.
  ///
  /// Not folded into [placeCurtain] because it also outlives the gesture
  /// instruction overlay, which some tests need to still be up.
  Future<void> dismissSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
  }

  setUp(() {
    messenger.setMockMethodCallHandler(
        _sensorsMethodChannel, (call) async => null);
    // The screen stages its placement .glb into the documents directory on
    // startup; point that at a scratch dir so the copy succeeds under test.
    messenger.setMockMethodCallHandler(
      _pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory'
          ? documentsDir.path
          : null,
    );
    // ARView embeds a real AndroidView. Once `runAsync` lets the real event
    // loop turn, it tries to create the platform view for real, so the
    // platform_views channel needs a stub (`create` returns a texture id).
    // Creation then fires onPlatformViewCreated, which spins up the plugin's
    // per-view channels — stub those against the id we are handed.
    messenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        if (call.method != 'create') return null;
        final args = call.arguments;
        final id = args is Map ? args['id'] as int? : null;
        if (id != null) {
          for (final prefix in ['arsession', 'arobjects', 'aranchors']) {
            final channel = MethodChannel('${prefix}_$id');
            arViewChannels.add(channel);
            if (prefix == 'arsession') {
              sessionChannelName = channel.name;
              messenger.setMockMethodCallHandler(channel, (call) async {
                sessionCalls.add(call);
                return null;
              });
            } else {
              final sink = prefix == 'arobjects' ? objectCalls : anchorCalls;
              messenger.setMockMethodCallHandler(channel, (call) async {
                sink.add(call);
                switch (call.method) {
                  // Anchored placement is stubbed as succeeding so the resize
                  // UI can be driven.
                  case 'addAnchor':
                  case 'addNodeToPlaneAnchor':
                    return true;
                  // Bare `addNode` is only ever the warm-up probe. It keeps
                  // returning null — the same signal a real device gives for a
                  // model it cannot compile — because the fallback test below
                  // depends on that branch being taken.
                  default:
                    return null;
                }
              });
            }
          }
        }
        return 0;
      },
    );
    messenger.setMockStreamHandler(
      _gyroscopeChannel,
      // Must not return a value: the return is encoded as the listen reply.
      MockStreamHandler.inline(onListen: (_, sink) {
        gyroSink = sink;
      }),
    );
    messenger.setMockStreamHandler(
      _userAccelChannel,
      MockStreamHandler.inline(onListen: (_, sink) {
        accelSink = sink;
      }),
    );
  });

  tearDown(() {
    gyroSink = null;
    accelSink = null;
    sessionCalls.clear();
    objectCalls.clear();
    anchorCalls.clear();
    sessionChannelName = null;
    messenger.setMockMethodCallHandler(_permissionChannel, null);
    messenger.setMockMethodCallHandler(_sensorsMethodChannel, null);
    messenger.setMockMethodCallHandler(_pathProviderChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final channel in arViewChannels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    arViewChannels.clear();
    messenger.setMockStreamHandler(_gyroscopeChannel, null);
    messenger.setMockStreamHandler(_userAccelChannel, null);
  });

  group('camera permission gate', () {
    testWidgets('shows the permission error UI when camera access is denied',
        (tester) async {
      stubPermissions(_kStatusDenied);

      await tester.pumpWidget(const MaterialApp(home: ArScreen()));
      await tester.pumpAndSettle();

      expect(
        find.text('Camera permission is required for AR preview'),
        findsOneWidget,
      );
      expect(find.text('Open Settings'), findsOneWidget);
      expect(find.byIcon(Icons.camera_alt), findsOneWidget);
      expect(find.text('Scanning...'), findsNothing);
    });

    testWidgets('requests permission when it has not been granted yet',
        (tester) async {
      final calls = stubPermissions(_kStatusDenied);

      await tester.pumpWidget(const MaterialApp(home: ArScreen()));
      await tester.pumpAndSettle();

      expect(calls, contains('checkPermissionStatus'));
      expect(calls, contains('requestPermissions'));
    });

    testWidgets('"Open Settings" invokes openAppSettings', (tester) async {
      final calls = stubPermissions(_kStatusDenied);

      await tester.pumpWidget(const MaterialApp(home: ArScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();

      expect(calls, contains('openAppSettings'));
    });

    testWidgets('does not show the permission error once granted',
        (tester) async {
      await pumpScanningScreen(tester);

      expect(
        find.text('Camera permission is required for AR preview'),
        findsNothing,
      );
    });
  });

  group('session configuration', () {
    testWidgets('asks the plugin for vertical planes only', (tester) async {
      await pumpScreenWithSession(tester);

      final init = sessionCalls.firstWhere((c) => c.method == 'init');
      // Curtains hang on walls. horizontalAndVertical made ARCore spend its
      // per-frame budget on floors, which is why nothing but the ground showed.
      expect(init.arguments['planeDetectionConfig'], _kPlaneDetectionVertical);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('leaves the point cloud off', (tester) async {
      await pumpScreenWithSession(tester);

      final init = sessionCalls.firstWhere((c) => c.method == 'init');
      // Android's onFrame allocates a fresh Filament material and a new cube
      // mesh per feature point per frame. This flag being true is the single
      // most expensive thing the session can do.
      expect(init.arguments['showFeaturePoints'], isFalse);
      expect(kShowFeaturePoints, isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('still renders detected planes so there is something to tap',
        (tester) async {
      await pumpScreenWithSession(tester);

      final init = sessionCalls.firstWhere((c) => c.method == 'init');
      expect(init.arguments['showPlanes'], isTrue);
      expect(init.arguments['handleTaps'], isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('supplies a plane texture, which is what makes walls visible',
        (tester) async {
      await pumpScreenWithSession(tester);

      final init = sessionCalls.firstWhere((c) => c.method == 'init');
      // showPlanes alone is not enough. Android only raises Sceneform's plane
      // spotlight radius from 0.5 m to 10 m inside the
      // `argCustomPlaneTexturePath?.let { }` block, and iOS falls back to a
      // 0.3-opacity white material without one — so detected walls read as
      // "not highlighted" until this is passed.
      expect(init.arguments['customPlaneTexturePath'], kPlaneTextureAssetPath);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the plane texture is a real bundled asset', (tester) async {
      // A path that is not registered in pubspec fails silently: Android's
      // Texture.builder future never completes and iOS's UIImage(named:)
      // returns nil, both falling back to the invisible default.
      final data = await rootBundle.load(kPlaneTextureAssetPath);
      expect(data.lengthInBytes, greaterThan(0));

      final header = data.buffer.asUint8List(data.offsetInBytes, 8);
      expect(header, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
          reason: 'must be a real PNG for both platform loaders');
    });
  });

  group('scanning UI', () {
    testWidgets('shows the wall-scanning overlay and chip', (tester) async {
      await pumpScanningScreen(tester);

      expect(find.text('AR Preview'), findsOneWidget);
      expect(find.text('Scanning...'), findsOneWidget);
      expect(
        find.text('Point your phone at the wall around your window'),
        findsOneWidget,
      );
      expect(find.text('Ready'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the tap-to-place prompt waits for a detected wall',
        (tester) async {
      await pumpScanningScreen(tester);

      expect(
        find.text('Tap a highlighted wall to place curtain'),
        findsNothing,
      );
      expect(find.text('Position confirmed ✓'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Reset and Next are both disabled before anything is placed',
        (tester) async {
      await pumpScanningScreen(tester);

      expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Reset'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Next →'))
            .onPressed,
        isNull,
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('elapsed scan counter starts at 0s and ticks up',
        (tester) async {
      await pumpScanningScreen(tester);

      expect(find.text('0s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('3s'), findsOneWidget);

      // Let the periodic timer go so the test can finish cleanly.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('guidance escalates the longer no wall is found',
        (tester) async {
      await pumpScanningScreen(tester);

      expect(
        find.text('Point your phone at the wall around your window'),
        findsOneWidget,
      );

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Sweep slowly across the wall'), findsOneWidget);

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(
        find.text('Still looking — try moving closer (0.5–1.5 m)'),
        findsOneWidget,
      );

      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Struggling to find a wall'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('wall detection', () {
    testWidgets('reports found walls in the status chip', (tester) async {
      await pumpScreenWithSession(tester);

      await emitSessionCallback(tester, 'onPlaneDetected', 1);
      expect(find.text('Ready • 1 wall'), findsOneWidget);

      await emitSessionCallback(tester, 'onPlaneDetected', 3);
      expect(find.text('Ready • 3 walls'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('swaps the scanning overlay for the tap prompt',
        (tester) async {
      await pumpScreenWithSession(tester);
      expect(find.text('Wall found!'), findsNothing);

      await emitSessionCallback(tester, 'onPlaneDetected', 1);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Wall found!'), findsOneWidget);
      expect(
        find.text('Tap a highlighted wall to place curtain'),
        findsOneWidget,
      );
      expect(
        find.text('Point your phone at the wall around your window'),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('stops the scan counter once a wall is found', (tester) async {
      await pumpScreenWithSession(tester);
      await tester.pump(const Duration(seconds: 2));

      await emitSessionCallback(tester, 'onPlaneDetected', 1);
      await tester.pump(const Duration(seconds: 5));

      // The counter is gone with the overlay, and its timer is cancelled — a
      // still-running periodic timer would be caught as a pending timer here.
      expect(find.textContaining('s', findRichText: false), findsWidgets);
      expect(find.text('7s'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('frame cost', () {
    testWidgets('the scanning pulse is the only running animation',
        (tester) async {
      await pumpScanningScreen(tester);

      // While scanning, the dial pulses forever by design.
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nothing keeps animating once a wall is found', (tester) async {
      await pumpScreenWithSession(tester);
      await emitSessionCallback(tester, 'onPlaneDetected', 1);

      // The overlay used to linger at zero opacity with its ticker still
      // running, burning a rebuild every frame for the rest of the session.
      // pumpAndSettle only returns if every animation has actually stopped.
      await tester.pumpAndSettle();

      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a sensor sample does not rebuild the AR platform view',
        (tester) async {
      await pumpScreenWithSession(tester);

      final before = tester.widget(find.byType(ARView));
      await emitSensor(tester, gyroSink, <double>[2.0, 0.0, 0.0]);
      await emitSensor(tester, gyroSink, <double>[0.0, 0.0, 0.0]);
      final after = tester.widget(find.byType(ARView));

      // The AR surface is cached in initState, so Element.updateChild sees the
      // identical widget and short-circuits the whole subtree.
      expect(identical(before, after), isTrue);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('curtain model', () {
    testWidgets(
        'falls back to the placeholder when the curtain will not render',
        (tester) async {
      // The stubbed addNode returns null, so the warm-up cannot compile a
      // renderable — the same signal a real device gives for a model it
      // cannot load. Staging succeeds here (curtain1.glb is a well-formed
      // container), so this covers the renderer-rejects-it branch.
      await pumpScreenWithSession(tester);
      await settlePreload(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Could not load curtain model — using placeholder shape'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('drops the loading strip once the model settles',
        (tester) async {
      await pumpScreenWithSession(tester);
      await settlePreload(tester);

      // Either outcome ends the load; what must not happen is the strip
      // hanging around forever.
      expect(find.text('Loading curtain...'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the Phase 3 calibration buttons are gone', (tester) async {
      await pumpScanningScreen(tester);

      // They existed only to find kInitialModelScale against a real export.
      // Leaving them next to the resize gestures would give two competing ways
      // to change the curtain's size.
      expect(find.text('Scale Up'), findsNothing);
      expect(find.text('Scale Down'), findsNothing);
      expect(find.textContaining('Scale: '), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('motion indicator', () {
    testWidgets('reads "Not moving" while the phone is stationary',
        (tester) async {
      await pumpScanningScreen(tester);

      expect(find.text('Not moving'), findsOneWidget);
      expect(
        find.text('Phone is stationary — move it to build depth'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reads "Scanning motion" for a gentle sweep', (tester) async {
      await pumpScanningScreen(tester);

      await emitSensor(tester, gyroSink, <double>[0.5, 0.0, 0.0]);

      expect(find.text('Scanning motion'), findsOneWidget);
      expect(find.text('Not moving'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('warns "Too fast" above the threshold', (tester) async {
      await pumpScanningScreen(tester);

      // Magnitude 2.0 rad/s, above the 1.5 threshold.
      await emitSensor(tester, gyroSink, <double>[2.0, 0.0, 0.0]);

      expect(find.text('Too fast'), findsOneWidget);
      expect(find.text('Slow down — moving too fast to track'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('translation alone counts as scanning motion', (tester) async {
      await pumpScanningScreen(tester);

      // Sliding the phone sideways barely rotates it, so the accelerometer is
      // what proves the user is actually moving.
      await emitSensor(tester, accelSink, <double>[0.4, 0.0, 0.0]);

      expect(find.text('Scanning motion'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  // ===================================================== phase 4: resizing

  group('resize maths', () {
    const start = CurtainMeasurements.initial;

    test('defaults to 100 × 200 cm sitting on the anchor', () {
      expect(start.widthCm, 100);
      expect(start.heightCm, 200);
      expect(start.offsetXCm, 0);
      expect(start.widthM, 1.0);
      expect(start.heightM, 2.0);
    });

    test('dragging up makes the curtain taller, at 0.5 cm per pixel', () {
      // Screen y grows downward, so dragging *up* is a negative dy.
      expect(start.withHeightDrag(-100).heightCm, 250);
      expect(start.withHeightDrag(-1).heightCm, 200.5);
    });

    test('dragging down makes it shorter', () {
      expect(start.withHeightDrag(100).heightCm, 150);
    });

    test('height clamps to 50–350 cm', () {
      expect(start.withHeightDrag(-100000).heightCm, kMaxHeightCm);
      expect(start.withHeightDrag(100000).heightCm, kMinHeightCm);
    });

    test('a height drag touches nothing else', () {
      final next = start.withHeightDrag(-60);
      expect(next.widthCm, start.widthCm);
      expect(next.offsetXCm, start.offsetXCm);
    });

    test('dragging right moves it right, at 0.3 cm per pixel', () {
      expect(start.withPositionDrag(100).offsetXCm, closeTo(30, 1e-9));
      expect(start.withPositionDrag(-100).offsetXCm, closeTo(-30, 1e-9));
    });

    test('the slide clamps to ±150 cm from the anchor', () {
      expect(start.withPositionDrag(100000).offsetXCm, kMaxOffsetCm);
      expect(start.withPositionDrag(-100000).offsetXCm, -kMaxOffsetCm);
    });

    test('repositioning changes position only, never width', () {
      final next = start.withPositionDrag(400);
      expect(next.widthCm, start.widthCm);
      expect(next.heightCm, start.heightCm);
    });

    test('pinch scales width relative to the width at gesture start', () {
      expect(start.withPinch(1.5).widthCm, 150);
      expect(start.withPinch(0.5).widthCm, 50);
      // Relative, not absolute — the same factor from a narrower start gives a
      // proportionally narrower result.
      expect(start.copyWith(widthCm: 60).withPinch(1.5).widthCm, 90);
    });

    test('width clamps to 30–250 cm', () {
      expect(start.withPinch(100).widthCm, kMaxWidthCm);
      expect(start.withPinch(0.001).widthCm, kMinWidthCm);
    });

    test('a pinch touches nothing else', () {
      final next = start.withPinch(1.8);
      expect(next.heightCm, start.heightCm);
      expect(next.offsetXCm, start.offsetXCm);
    });

    test('clamping is reversible', () {
      // Every update recomputes from the snapshot taken at gesture start rather
      // than accumulating, so dragging back out of a limit follows the finger
      // instead of sticking there.
      expect(start.withHeightDrag(-100000).heightCm, kMaxHeightCm);
      expect(start.withHeightDrag(-100).heightCm, 250);
    });
  });

  group('drag axis lock', () {
    test('stays ambiguous inside the 10 px dead zone', () {
      expect(axisForDrag(Offset.zero), isNull);
      expect(axisForDrag(const Offset(6, 6)), isNull); // 8.49 px
    });

    test('a mostly-vertical drag adjusts height', () {
      expect(axisForDrag(const Offset(4, 30)), GestureAxis.height);
      expect(axisForDrag(const Offset(-4, -30)), GestureAxis.height);
    });

    test('a mostly-horizontal drag repositions', () {
      expect(axisForDrag(const Offset(30, 4)), GestureAxis.position);
      expect(axisForDrag(const Offset(-30, -4)), GestureAxis.position);
    });

    test('a dead-even diagonal picks one instead of flapping', () {
      expect(axisForDrag(const Offset(20, 20)), GestureAxis.position);
    });
  });

  group('limit haptics', () {
    const start = CurtainMeasurements.initial;

    test('fires on the transition into a limit', () {
      expect(hitLimit(start, start.copyWith(heightCm: kMaxHeightCm)), isTrue);
      expect(hitLimit(start, start.copyWith(widthCm: kMinWidthCm)), isTrue);
      expect(hitLimit(start, start.copyWith(offsetXCm: kMaxOffsetCm)), isTrue);
      expect(hitLimit(start, start.copyWith(offsetXCm: -kMaxOffsetCm)), isTrue);
    });

    test('stays quiet while already pinned', () {
      final pinned = start.copyWith(heightCm: kMaxHeightCm);
      expect(hitLimit(pinned, pinned), isFalse);
    });

    test('stays quiet during ordinary adjustment', () {
      expect(hitLimit(start, start.withHeightDrag(-100)), isFalse);
      expect(hitLimit(start, start.withPinch(1.2)), isFalse);
    });

    test('tracks each dimension separately', () {
      // A height bottoming out must still buzz while the width happens to be
      // sitting at its maximum. A single "is anything pinned" flag would not.
      final maxedWidth = start.copyWith(widthCm: kMaxWidthCm);
      expect(
        hitLimit(maxedWidth, maxedWidth.copyWith(heightCm: kMinHeightCm)),
        isTrue,
      );
    });
  });

  group('resize gestures', () {
    /// Reads a live value straight out of the measurement card.
    double readCard(WidgetTester tester, String label) {
      final row = find
          .ancestor(of: find.text('$label:'), matching: find.byType(Row))
          .first;
      final text = tester.widget<Text>(
        find.descendant(of: row, matching: find.textContaining(' cm')),
      );
      return double.parse(text.data!.replaceAll(' cm', ''));
    }

    /// One-finger drag delivered in increments.
    ///
    /// A single large `moveBy` would be accepted and ended inside one frame, so
    /// the recognizer would fire start and end with no update in between — and
    /// updates are the only thing that moves the curtain.
    Future<void> dragBy(WidgetTester tester, Offset total) async {
      const steps = 10;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ARView)),
      );
      for (var i = 0; i < steps; i++) {
        await gesture.moveBy(total / steps.toDouble());
        await tester.pump();
      }
      await gesture.up();
      // Let the counter tween land on the final value.
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// Two-finger pinch to [factor] times the starting span.
    Future<void> pinchTo(WidgetTester tester, double factor) async {
      const steps = 10;
      const spread = 100.0;
      final centre = tester.getCenter(find.byType(ARView));
      final left = await tester.startGesture(centre - const Offset(spread, 0));
      final right = await tester.startGesture(centre + const Offset(spread, 0));
      for (var i = 1; i <= steps; i++) {
        final half = spread + (spread * factor - spread) * i / steps;
        await left.moveTo(centre - Offset(half, 0));
        await right.moveTo(centre + Offset(half, 0));
        await tester.pump();
      }
      await left.up();
      await right.up();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('no measurement card until something is placed', (tester) async {
      await pumpScreenWithSession(tester);

      expect(find.text('Width:'), findsNothing);
      expect(find.text('Height:'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('placing shows the card at the 100 × 200 default',
        (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      expect(find.text('Placed'), findsOneWidget);
      expect(readCard(tester, 'Width'), 100);
      expect(readCard(tester, 'Height'), 200);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('gestures do nothing before a curtain is placed',
        (tester) async {
      await pumpScreenWithSession(tester);
      await settlePreload(tester);
      await emitSessionCallback(tester, 'onPlaneDetected', 1);

      // Nothing to resize yet, so the drag must not create a readout.
      await dragBy(tester, const Offset(0, -300));
      expect(find.text('Width:'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('dragging up makes the curtain taller, down shorter',
        (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      await dragBy(tester, const Offset(0, -200));
      final taller = readCard(tester, 'Height');
      expect(taller, greaterThan(200));
      // Height only — a vertical drag must not touch the width.
      expect(readCard(tester, 'Width'), 100);

      await dragBy(tester, const Offset(0, 200));
      expect(readCard(tester, 'Height'), lessThan(taller));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('height clamps at both ends of the range', (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      await dragBy(tester, const Offset(0, -4000));
      expect(readCard(tester, 'Height'), kMaxHeightCm);

      await dragBy(tester, const Offset(0, 4000));
      expect(readCard(tester, 'Height'), kMinHeightCm);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a horizontal drag repositions without resizing anything',
        (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      await dragBy(tester, const Offset(300, 0));

      // The slide is a position change, so neither readout may move.
      expect(readCard(tester, 'Width'), 100);
      expect(readCard(tester, 'Height'), 200);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pinching out widens and pinching in narrows', (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      await pinchTo(tester, 1.6);
      expect(readCard(tester, 'Width'), greaterThan(100));
      // Width only — a pinch must not change the drop.
      expect(readCard(tester, 'Height'), 200);

      await pinchTo(tester, 0.4);
      expect(readCard(tester, 'Width'), lessThan(100));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('width clamps at both ends of the range', (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      await pinchTo(tester, 4);
      expect(readCard(tester, 'Width'), kMaxWidthCm);

      await pinchTo(tester, 0.05);
      expect(readCard(tester, 'Width'), kMinWidthCm);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('adding a second finger mid-drag keeps the height already set',
        (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      final centre = tester.getCenter(find.byType(ARView));
      final first = await tester.startGesture(centre);
      for (var i = 0; i < 10; i++) {
        await first.moveBy(const Offset(0, -30));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
      final taller = readCard(tester, 'Height');
      expect(taller, greaterThan(200));

      // Second finger down without lifting the first: the gesture becomes a
      // pinch. Every update recomputes from the snapshot taken at scale-start,
      // so without re-baselining the height would spring back to 200.
      final second = await tester.startGesture(centre + const Offset(120, 0));
      for (var i = 1; i <= 6; i++) {
        await second.moveBy(const Offset(20, 0));
        await tester.pump();
      }
      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 300));

      expect(readCard(tester, 'Height'), taller);
      expect(readCard(tester, 'Width'), greaterThan(100));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('lifting one finger mid-pinch leaves the width where it was',
        (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      final centre = tester.getCenter(find.byType(ARView));
      final left = await tester.startGesture(centre - const Offset(100, 0));
      final right = await tester.startGesture(centre + const Offset(100, 0));
      for (var i = 1; i <= 6; i++) {
        await left.moveBy(const Offset(-15, 0));
        await right.moveBy(const Offset(15, 0));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
      final widened = readCard(tester, 'Width');
      expect(widened, greaterThan(100));

      // One finger up, the other keeps moving. There is no one-finger reading
      // of a width lock, so the width must simply hold.
      await left.up();
      for (var i = 0; i < 6; i++) {
        await right.moveBy(const Offset(0, -30));
        await tester.pump();
      }
      await right.up();
      await tester.pump(const Duration(milliseconds: 300));

      expect(readCard(tester, 'Width'), widened);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the node scale follows the readout to the wall',
        (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);
      objectCalls.clear();

      await dragBy(tester, const Offset(0, 4000)); // all the way to 50 cm

      final writes =
          objectCalls.where((c) => c.method == 'transformationChanged').toList();
      expect(writes, isNotEmpty);

      // The last write is the forced one from onScaleEnd, so the node must have
      // landed on exactly what the card shows rather than on whatever the write
      // throttle last let through.
      final matrix = vm.Matrix4.fromList(
        (writes.last.arguments['transformation'] as List).cast<double>(),
      );
      final yAxis = matrix.getColumn(1);
      // 0.5 m of drop against a 2 m nominal model.
      expect(
        vm.Vector3(yAxis.x, yAxis.y, yAxis.z).length,
        closeTo(kMinHeightCm / 100 / kNominalModelHeightM, 1e-6),
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('transform writes are throttled below the update rate',
        (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);
      objectCalls.clear();

      await dragBy(tester, const Offset(0, -300));

      // Every write is a channel round trip plus a recursive scene-graph walk
      // on Android, and a real drag produces one update per vsync.
      final writes =
          objectCalls.where((c) => c.method == 'transformationChanged').length;
      expect(writes, greaterThan(0));
      expect(writes, lessThan(10));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Reset restores the defaults', (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      await dragBy(tester, const Offset(0, -4000));
      await pinchTo(tester, 4);
      expect(readCard(tester, 'Height'), kMaxHeightCm);
      expect(readCard(tester, 'Width'), kMaxWidthCm);

      await dismissSnackBar(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Reset'));
      // Two frames: the first rebuilds the card and starts the counter tween
      // at its old value, the second lets the tween run to the new one.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(readCard(tester, 'Width'), 100);
      expect(readCard(tester, 'Height'), 200);
      // Reset keeps the placement — the anchor is what "original position"
      // means, and re-scanning the wall to get back would be worse than
      // useless.
      expect(find.text('Placed'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('gesture instructions', () {
    testWidgets('appear on the first placement and auto-dismiss',
        (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      expect(find.text('Drag up/down to adjust height'), findsOneWidget);
      expect(find.text('Drag left/right to reposition'), findsOneWidget);
      expect(find.text('Pinch to adjust width'), findsOneWidget);

      await tester.pump(kInstructionOverlayDuration);
      expect(find.text('Pinch to adjust width'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('do not come back on a second placement', (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);
      await tester.pump(kInstructionOverlayDuration);

      await emitSessionCallback(tester, 'onPlaneOrPointTap', <Object>[_wallHit]);
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }

      expect(find.text('Pinch to adjust width'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('do not swallow a resize gesture while showing', (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);
      expect(find.text('Pinch to adjust width'), findsOneWidget);

      // The legend covers the middle of the AR view for three seconds. A user
      // who starts dragging straight away must not be blocked by it.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ARView)),
      );
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));

      final height = tester.widget<Text>(
        find.descendant(
          of: find
              .ancestor(of: find.text('Height:'), matching: find.byType(Row))
              .first,
          matching: find.textContaining(' cm'),
        ),
      );
      expect(double.parse(height.data!.replaceAll(' cm', '')),
          greaterThan(200));

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('measurement capture', () {
    testWidgets('Next → reports the live numbers in a dialog', (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);
      await dismissSnackBar(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Next →'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('AR Measurement Captured'), findsOneWidget);
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(of: dialog, matching: find.text('100 cm')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('200 cm')),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'OK'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('AR Measurement Captured'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Reset and Next enable once a curtain is placed',
        (tester) async {
      await pumpScreenWithSession(tester);
      await placeCurtain(tester);

      expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Reset'))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Next →'))
            .onPressed,
        isNotNull,
      );

      await tester.pumpWidget(const SizedBox());
    });
  });
}
