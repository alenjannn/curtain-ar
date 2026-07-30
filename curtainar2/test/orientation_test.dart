// Covers the placement rectangle's orientation maths — the one part of phase 2
// that has no visual fallback: get it wrong and the quad lies flat on the floor
// or clips through the wall, and neither is obvious from a console log.
//
// The quad is authored in the XY plane facing +Z, 1.0 x 2.0 m, centred on its
// origin. `rectRotationForHit` returns its rotation *relative to the anchor*,
// so a corner's world position is anchorPose * nodeTransform * corner.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import 'package:simply_curtains_ar/screens/ar_screen.dart';

/// A plane hit pose, built the way ARCore and ARKit build them: local +Y is the
/// surface normal. [inPlaneTwist] rotates the pose about that normal, which is
/// the part the two platforms pick arbitrarily.
vm.Matrix4 planeHit({
  required vm.Vector3 normal,
  required vm.Vector3 position,
  double inPlaneTwist = 0,
}) {
  final n = normal.normalized();
  // Any vector not parallel to the normal will do for the seed axis.
  final seed = n.y.abs() > 0.9 ? vm.Vector3(1, 0, 0) : vm.Vector3(0, 1, 0);
  final x = seed.cross(n).normalized();
  final z = x.cross(n).normalized();
  final basis = vm.Matrix3.columns(x, n, z);
  final twist = vm.Quaternion.axisAngle(n, inPlaneTwist).asRotationMatrix();
  return vm.Matrix4.identity()
    ..setRotation(twist * basis as vm.Matrix3)
    ..setTranslation(position);
}

/// The quad's four corners in world space, in order: bottom-left, bottom-right,
/// top-right, top-left.
List<vm.Vector3> worldCorners(vm.Matrix4 hit, vm.Vector3? camera) {
  final node = vm.Matrix4.compose(
    vm.Vector3.zero(),
    rectRotationForHit(hit, camera),
    vm.Vector3.all(1),
  );
  final world = hit.clone()..multiply(node);
  return [
    world.transformed3(vm.Vector3(-kRectWidthM / 2, -kRectHeightM / 2, 0)),
    world.transformed3(vm.Vector3(kRectWidthM / 2, -kRectHeightM / 2, 0)),
    world.transformed3(vm.Vector3(kRectWidthM / 2, kRectHeightM / 2, 0)),
    world.transformed3(vm.Vector3(-kRectWidthM / 2, kRectHeightM / 2, 0)),
  ];
}

void main() {
  group('vertical surfaces', () {
    test('a wall hit reduces to the R_x(-pi/2) the brief calls for', () {
      final hit = planeHit(
        normal: vm.Vector3(0, 0, 1),
        position: vm.Vector3(1, 1.5, -2),
      );

      final actual =
          rectRotationForHit(hit, vm.Vector3(1, 1.5, 0)).asRotationMatrix();
      final expected =
          vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), -math.pi / 2)
              .asRotationMatrix();

      expect(
          (actual - expected).absoluteError(vm.Matrix3.zero()), lessThan(1e-9));
    });

    test('is classified as vertical', () {
      expect(
        isVerticalSurface(planeHit(
          normal: vm.Vector3(0, 0, 1),
          position: vm.Vector3.zero(),
        )),
        isTrue,
      );
    });

    test('hangs plumb and sits flush regardless of the in-plane axis', () {
      // The fixed -pi/2 shortcut only works when the platform happens to pick
      // the in-plane X axis we assumed; these twists are what break it.
      for (final twist in [0.0, 0.7, -1.3, math.pi]) {
        final hit = planeHit(
          normal: vm.Vector3(0, 0, 1),
          position: vm.Vector3(0, 1.5, -2),
          inPlaneTwist: twist,
        );
        final corners = worldCorners(hit, vm.Vector3(0, 1.5, 0));
        final reason = 'twist=$twist';

        expect((corners[1] - corners[0]).length, closeTo(kRectWidthM, 1e-9),
            reason: reason);
        expect((corners[3] - corners[0]).length, closeTo(kRectHeightM, 1e-9),
            reason: reason);
        // Bottom edge level, side edge straight up.
        expect((corners[1] - corners[0]).y.abs(), lessThan(1e-9),
            reason: reason);
        expect((corners[3] - corners[0]).normalized().y, closeTo(1.0, 1e-9),
            reason: reason);
        // Every corner at the wall's depth.
        for (final corner in corners) {
          expect(corner.z, closeTo(-2.0, 1e-9), reason: reason);
        }
        // Centred on the tap point.
        expect(
            ((corners[0] + corners[2]) / 2.0 - vm.Vector3(0, 1.5, -2)).length,
            lessThan(1e-9),
            reason: reason);
      }
    });

    test('faces out of the wall, not into it', () {
      final hit = planeHit(
        normal: vm.Vector3(0, 0, 1),
        position: vm.Vector3(0, 1.5, -2),
      );
      final corners = worldCorners(hit, vm.Vector3(0, 1.5, 0));
      final faceNormal =
          (corners[1] - corners[0]).cross(corners[3] - corners[0]).normalized();

      expect(faceNormal.z, closeTo(1.0, 1e-9));
    });

    test('a wall at an angle still hangs plumb', () {
      final hit = planeHit(
        normal: vm.Vector3(0.6, 0, 0.8),
        position: vm.Vector3(0, 1.4, -2),
        inPlaneTwist: 0.4,
      );
      final corners = worldCorners(hit, vm.Vector3(0, 1.4, 0));

      expect((corners[3] - corners[0]).normalized().y, closeTo(1.0, 1e-9));
      expect((corners[1] - corners[0]).y.abs(), lessThan(1e-9));
      expect((corners[1] - corners[0]).length, closeTo(kRectWidthM, 1e-9));
    });
  });

  group('horizontal surfaces', () {
    test('is not classified as vertical', () {
      expect(
        isVerticalSurface(planeHit(
          normal: vm.Vector3(0, 1, 0),
          position: vm.Vector3.zero(),
        )),
        isFalse,
      );
    });

    test('stands the quad upright facing the camera instead of lying it flat',
        () {
      final hit = planeHit(
        normal: vm.Vector3(0, 1, 0),
        position: vm.Vector3(0, 0, -3),
        inPlaneTwist: 1.1,
      );
      final corners = worldCorners(hit, vm.Vector3(0, 1.4, 0));

      expect((corners[1] - corners[0]).length, closeTo(kRectWidthM, 1e-9));
      expect((corners[3] - corners[0]).length, closeTo(kRectHeightM, 1e-9));
      // Upright, not flat on the floor.
      expect((corners[3] - corners[0]).normalized().y, closeTo(1.0, 1e-9));

      final faceNormal =
          (corners[1] - corners[0]).cross(corners[3] - corners[0]).normalized();
      expect(faceNormal.z, closeTo(1.0, 1e-9));
      expect(faceNormal.y.abs(), lessThan(1e-9));
    });

    test('falls back to a sane facing when the camera pose is unknown', () {
      final hit = planeHit(
        normal: vm.Vector3(0, 1, 0),
        position: vm.Vector3(0, 0, -3),
      );
      final corners = worldCorners(hit, null);

      expect((corners[3] - corners[0]).normalized().y, closeTo(1.0, 1e-9));
      expect((corners[1] - corners[0]).length, closeTo(kRectWidthM, 1e-9));
    });

    test('degenerate camera-directly-overhead does not produce NaN', () {
      final hit = planeHit(
        normal: vm.Vector3(0, 1, 0),
        position: vm.Vector3(0, 0, -3),
      );
      // Camera straight above the hit: the horizontal look direction is zero.
      final corners = worldCorners(hit, vm.Vector3(0, 2, -3));

      for (final corner in corners) {
        expect(corner.x.isNaN || corner.y.isNaN || corner.z.isNaN, isFalse);
      }
      expect((corners[3] - corners[0]).normalized().y, closeTo(1.0, 1e-9));
    });
  });
}
