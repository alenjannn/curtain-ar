// Smoke test for the Simply Curtains AR home screen.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:simply_curtains_ar/main.dart';
import 'package:simply_curtains_ar/screens/ar_screen.dart';
import 'package:simply_curtains_ar/screens/home_screen.dart';

const MethodChannel _permissionChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');
const String _gyroscopeChannel = 'dev.fluttercommunity.plus/sensors/gyroscope';

void main() {
  testWidgets('HomeScreen renders title, subtitle and AR button',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SimplyCurtainsApp());
    // flutter_animate drives an implicit animation, so settle the frames first.
    await tester.pumpAndSettle();

    expect(find.text('Simply Curtains AR'), findsOneWidget);
    expect(find.text('AR Feasibility Prototype'), findsOneWidget);
    expect(find.text('Launch AR Preview'), findsOneWidget);
  });

  testWidgets('"Launch AR Preview" navigates to the AR screen',
      (WidgetTester tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Deny the camera so ArScreen settles on its permission UI instead of
    // trying to stand up a real AR platform view.
    messenger.setMockMethodCallHandler(_permissionChannel, (call) async {
      if (call.method == 'checkPermissionStatus') return 0;
      if (call.method == 'requestPermissions') return <int, int>{1: 0};
      return null;
    });
    messenger.setMockStreamHandler(
      const EventChannel(_gyroscopeChannel),
      MockStreamHandler.inline(onListen: (arguments, sink) {}),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(_permissionChannel, null);
      messenger.setMockStreamHandler(
          const EventChannel(_gyroscopeChannel), null);
    });

    await tester.pumpWidget(const SimplyCurtainsApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Launch AR Preview'));
    await tester.pumpAndSettle();

    expect(find.byType(ArScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
