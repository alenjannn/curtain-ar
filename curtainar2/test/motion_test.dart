// The motion classifier used to be a plain threshold compare, and every time it
// flipped it called setState on the whole AR screen. A phone held near a
// boundary flipped it many times a second, so this is a performance test as much
// as a correctness one: the same jitter must produce a stable answer.

import 'package:flutter_test/flutter_test.dart';

import 'package:simply_curtains_ar/screens/ar_screen.dart';

void main() {
  group('classifyMotion', () {
    test('a stationary phone reads as still', () {
      expect(classifyMotion(0.0, 0.0, MotionState.still), MotionState.still);
      expect(classifyMotion(0.01, 0.02, MotionState.still), MotionState.still);
    });

    test('a gentle sweep reads as good', () {
      expect(classifyMotion(0.5, 0.0, MotionState.still), MotionState.good);
    });

    test('translation alone counts as movement', () {
      // Sliding the phone sideways barely rotates it, so the accelerometer is
      // what proves the user is actually moving.
      expect(classifyMotion(0.0, 0.4, MotionState.still), MotionState.good);
    });

    test('fast rotation reads as too fast', () {
      expect(classifyMotion(2.0, 0.0, MotionState.good), MotionState.tooFast);
    });

    test('leaving "too fast" needs a lower reading than entering it', () {
      // 1.3 is above the exit threshold but below the enter threshold.
      expect(classifyMotion(1.3, 0.0, MotionState.good), MotionState.good);
      expect(
          classifyMotion(1.3, 0.0, MotionState.tooFast), MotionState.tooFast);
    });

    test('leaving "still" needs a higher reading than entering it', () {
      expect(classifyMotion(0.10, 0.0, MotionState.good), MotionState.good);
      expect(classifyMotion(0.10, 0.0, MotionState.still), MotionState.still);
    });

    test('jitter around a boundary does not flap', () {
      // Alternating samples that straddle the "too fast" line. Without
      // hysteresis this alternates tooFast/good on every sample; each flip was
      // a full-screen rebuild.
      var state = MotionState.good;
      final observed = <MotionState>{};
      for (var i = 0; i < 20; i++) {
        final gyro = i.isEven ? 1.45 : 1.25;
        state = classifyMotion(gyro, 0.0, state);
        observed.add(state);
      }
      expect(observed, {MotionState.good},
          reason: 'sub-threshold jitter should never enter tooFast');

      state = MotionState.tooFast;
      observed.clear();
      for (var i = 0; i < 20; i++) {
        final gyro = i.isEven ? 1.45 : 1.25;
        state = classifyMotion(gyro, 0.0, state);
        observed.add(state);
      }
      expect(observed, {MotionState.tooFast},
          reason: 'once latched, the same jitter should not drop out');
    });

    test('a decisive change still gets through in one sample', () {
      expect(classifyMotion(3.0, 0.0, MotionState.still), MotionState.tooFast);
      expect(classifyMotion(0.0, 0.0, MotionState.tooFast), MotionState.still);
    });
  });

  group('scanning guidance', () {
    test('escalates as time passes', () {
      expect(
          scanHeadline(0), 'Point your phone at the wall around your window');
      expect(scanHeadline(6), 'Sweep slowly across the wall');
      expect(scanHeadline(16), 'Still looking — try moving closer (0.5–1.5 m)');
      expect(scanHeadline(31), 'Struggling to find a wall');
    });

    test('motion problems take priority over the elapsed-time advice', () {
      expect(scanHint(31, MotionState.still),
          'Phone is stationary — move it to build depth');
      expect(scanHint(31, MotionState.tooFast),
          'Slow down — moving too fast to track');
    });

    test('late-stage advice names the real ARCore limitation for walls', () {
      // Vertical planes are fitted from texture, so a bare painted wall can
      // genuinely never resolve. Saying so is the difference between the user
      // waiting forever and pointing at the frame.
      expect(scanHint(31, MotionState.good), contains('Blank walls'));
      expect(scanHint(16, MotionState.good), contains('frame'));
    });
  });
}
