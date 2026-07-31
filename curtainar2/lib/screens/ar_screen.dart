import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ar_flutter_plugin_updated/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_updated/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_updated/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_updated/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_updated/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_updated/models/ar_node.dart';
import 'package:ar_flutter_plugin_updated/widgets/ar_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../models/swatch.dart';
import '../widgets/swatch_selector.dart';

// ------------------------------------------------------------ plane detection

/// Curtains hang on walls, so only vertical planes are worth tracking. This maps
/// to `PlaneFindingMode.VERTICAL` on ARCore and `.vertical` on ARKit.
///
/// It is also the faster setting: with `horizontalAndVertical` ARCore splits its
/// per-frame budget across both, and floors win because they are easier to fit —
/// which is why the app used to find nothing but the ground.
const PlaneDetectionConfig kPlaneDetectionConfig =
    PlaneDetectionConfig.vertical;

/// Renders ARCore's raw point cloud. **Keep this false outside debugging.**
///
/// The Android implementation rebuilds the whole cloud every single frame:
/// `onFrame` tears down every node, then calls `makeFeaturePointNode` once per
/// point, and each of those allocates a fresh Filament material *and* builds a
/// new cube mesh (ArModelBuilder.kt:37). At 50-300 points that is thousands of
/// GPU buffer allocations per second, and it is the single largest cost in the
/// session. It does not even render — the renderable is read before the async
/// material future completes — so the cost buys nothing.
const bool kShowFeaturePoints = false;

// --------------------------------------------------------------------- motion

/// Angular velocity (rad/s) above which the phone is moving too fast to track.
/// Paired enter/exit values: a single threshold makes the state flap while the
/// user hovers around it, and every flap used to rebuild the entire screen.
const double kTooFastEnter = 1.5;
const double kTooFastExit = 1.2;

/// Below these, the phone is effectively stationary. ARCore needs parallax from
/// actual movement to resolve depth, so "too still" is a real failure mode.
const double kStillGyroEnter = 0.08;
const double kStillGyroExit = 0.14;
const double kStillAccelEnter = 0.15;
const double kStillAccelExit = 0.25;

/// The window in which a wall is normally found. Used for the elapsed-time
/// readout only — see [_ScanStage]; it is NOT scan progress.
const Duration kTypicalScanDuration = Duration(seconds: 15);

/// Distance band where curtain placement will be most accurate.
const double kIdealMinDistanceM = 0.5;
const double kIdealMaxDistanceM = 1.5;

const Duration kSurfaceFoundToastDuration = Duration(seconds: 2);
const Duration kPlacementHintDuration = Duration(seconds: 3);
const Duration kScanFadeDuration = Duration(milliseconds: 350);

// ------------------------------------------------------------------ placement

/// Authored dimensions of the panel, in metres. What the user sees is driven by
/// [CurtainMeasurements]; these describe the geometry itself, and are what
/// test/orientation_test.dart measures the placed corners against.
///
/// Phase 5 no longer ships a model: the panel's GLB is authored at runtime by
/// [buildBoxGlb] so a swatch colour can be baked into its material. The plugin
/// offers no primitive geometry and no way to touch a loaded model's materials,
/// so the colour has to live in the file.
const double kRectWidthM = 1.0;
const double kRectHeightM = 2.0;

/// Texture for the detected-wall highlight, and the reason walls now show up.
///
/// Neither platform draws a usable highlight without one. On Android the plugin
/// raises Sceneform's plane spotlight radius from 0.5 m to 10 m *only* inside
/// `argCustomPlaneTexturePath?.let { ... }` (AndroidARView.kt:560-589), so
/// without this the highlight is a faint dot grid confined to half a metre
/// around wherever the camera is pointing. On iOS `makePlane` falls back to
/// SCNPlane's default white material at 0.3 opacity when no texture is given.
const String kPlaneTextureAssetPath = 'assets/textures/plane_grid.png';

/// Multiplier that renders the model at its nominal size
/// ([kNominalModelWidthM] × [kNominalModelHeightM]).
///
/// Still 1.0 because Phase 3's calibration never ran against a real model —
/// both curtain assets are placeholders. Once a Meshy export lands, read the
/// `GLB INSPECT` line at startup and set this to the suggested value; every
/// dimension below is expressed relative to it, so nothing else changes.
const double kInitialModelScale = 1.0;

/// The model's real-world size at [kInitialModelScale]. Gesture dimensions are
/// ratios against this, so a corrected scale does not shift the readouts.
const double kNominalModelWidthM = 1.0;
const double kNominalModelHeightM = 2.0;

const Duration kPlacementAnimDuration = Duration(milliseconds: 400);

// ---------------------------------------------------------------- phase 5

/// Thickness of the panel. Width and height come from the live measurements;
/// only the depth is fixed, because a curtain panel does not get thicker when
/// you make it wider.
const double kPanelDepthM = 0.05;

/// White flash on capture, then the fade. Short enough not to hide the shot.
const Duration kShutterFlashDuration = Duration(milliseconds: 150);
const Duration kShutterFadeDuration = Duration(milliseconds: 250);

/// How long the saved-shot thumbnail stays up before fading out.
const Duration kThumbnailDuration = Duration(seconds: 4);
const Duration kThumbnailFadeDuration = Duration(milliseconds: 400);
const double kThumbnailSize = 72;

/// A colour swap re-anchors and re-adds the node, so it is not free. Anything
/// past this is worth flagging as a visible hitch during Phase 5 evaluation.
const int kSwatchSwapFlickerMs = 120;

// ------------------------------------------------------------ resize gestures

const double kDefaultWidthCm = 100.0;
const double kDefaultHeightCm = 200.0;

const double kMinWidthCm = 30.0;
const double kMaxWidthCm = 250.0;
const double kMinHeightCm = 50.0;
const double kMaxHeightCm = 350.0;

/// How far the curtain may slide along the wall from its anchor, either way.
const double kMaxOffsetCm = 150.0;

const double kHeightCmPerPixel = 0.5;
const double kOffsetCmPerPixel = 0.3;

/// Travel before a one-finger drag commits to an axis. Below this the drag is
/// ambiguous and nothing moves.
const double kAxisLockSlopPx = 10.0;

const Duration kInstructionOverlayDuration = Duration(seconds: 3);

/// The instruction overlay's own timeline, which has to add up to
/// [kInstructionOverlayDuration]: the widget is unmounted when that elapses, so
/// a fade-out running past it would be cut off mid-fade.
const Duration kInstructionFadeIn = Duration(milliseconds: 300);
const Duration kInstructionFadeOut = Duration(milliseconds: 400);
const Duration kInstructionHold = Duration(milliseconds: 2300);

/// Dark navy at 85% (0xD9). Opaque enough to read white text over a bright
/// camera feed, sheer enough that the wall being measured still shows through.
const Color kMeasurementCardColor = Color(0xD90A1A33);

/// Short enough that the readout still tracks the finger, long enough to stop
/// the digits strobing during a fast drag.
const Duration kMeasurementTweenDuration = Duration(milliseconds: 120);

/// Minimum gap between transform writes during the pop-in. Every write is a
/// platform-channel round trip, and Android's handler does a recursive
/// `scene.findByName` per call — at vsync rate that is ~36 tree walks for a
/// 300 ms animation. ~30 Hz looks identical and costs a third as much.
const Duration kTransformWriteInterval = Duration(milliseconds: 32);

/// Android decomposes the node matrix by dividing each basis column by its own
/// length, so an exactly-zero scale yields NaN. Start the pop-in just above it.
const double kMinPlacementScale = 0.001;

/// Both platform loaders shrink every child of a loaded model by 0.01 ("meters
/// vs. millimeters" compensation in ArModelBuilder.swift). Only iOS applies it
/// to the node we actually control, so iOS needs it cancelled back out.
final double kModelScaleCompensation =
    defaultTargetPlatform == TargetPlatform.iOS ? 100.0 : 1.0;

/// A surface counts as a wall when its normal is within ~60° of horizontal.
const double kVerticalNormalTolerance = 0.5;

// ------------------------------------------------------------------ tracking

/// How far the camera must travel before we re-log the anchor's status.
const double kCameraMoveLogThresholdM = 0.5;

/// How far the anchor may drift from its placement position and still count as
/// holding. ARCore nudges anchors as it refines the map; centimetres are fine.
const double kAnchorDriftToleranceM = 0.05;

const Duration kPosePollInterval = Duration(milliseconds: 500);

/// Camera translation below this between two polls counts as "the pose did not
/// move at all", which is only suspicious while the sensors say we are moving.
const double kFrozenPoseEpsilonM = 0.0005;

/// Consecutive bad polls before we call it: one dropped frame is not a loss.
const int kTrackingStrikesForLoss = 2;

/// iOS never invokes `onPlaneOrPointTap` when the hit test comes back empty
/// (IosARView.swift guards on `count != 0`), so a miss produces no callback at
/// all. We arm a timer on every tap and treat silence as a miss.
const Duration kTapMissTimeout = Duration(milliseconds: 350);
const double kTapSlopPx = 20;
const Duration kTapMaxDuration = Duration(milliseconds: 500);

enum _PermissionState { checking, granted, denied }

/// How the phone is currently being moved, derived from live sensor data.
enum MotionState { still, good, tooFast }

/// Escalating guidance based on how long we have been scanning without a hit.
enum _ScanStage { starting, scanning, slow, struggling }

/// How far the curtain model has got. The UI keys off this for the loading
/// strip, the tap spinner and the fallback banner.
enum ModelLoadState {
  /// Staging and/or warming the renderable.
  loading,

  /// The curtain is staged and its renderable is compiled — taps place instantly.
  ready,

  /// The curtain could not be loaded; taps place the Phase 2 blue rectangle.
  fallback,
}

/// Validates the GLB *container* before the file is handed to the native
/// loader.
///
/// Worth doing because both platforms fail opaquely on a malformed model —
/// Sceneform reports "Unable to load renderable" and GLTFSceneKit throws a
/// generic parse error, neither of which tells you the file is a text
/// placeholder. Returns null when the container is well formed, otherwise a
/// message suitable for the console and the fallback banner.
///
/// This checks the wrapper only: chunk framing, magic, version, declared
/// length. A structurally valid GLB holding a bad mesh still passes.
@visibleForTesting
String? glbContainerError(Uint8List bytes) {
  const int glbMagic = 0x46546C67; // 'glTF', little-endian
  const int jsonChunkType = 0x4E4F534A; // 'JSON'
  const int headerLength = 12;
  const int chunkHeaderLength = 8;

  if (bytes.lengthInBytes < headerLength + chunkHeaderLength) {
    return 'file is only ${bytes.lengthInBytes} bytes — too short to be a GLB '
        '(is it a placeholder or a Git LFS pointer?)';
  }

  final data = ByteData.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );

  final magic = data.getUint32(0, Endian.little);
  if (magic != glbMagic) {
    return 'not a GLB: expected magic 0x46546C67, got '
        '0x${magic.toRadixString(16).padLeft(8, '0')}';
  }

  final version = data.getUint32(4, Endian.little);
  if (version != 2) {
    return 'unsupported glTF binary version $version — only version 2 is '
        'supported (a text file starting with "glTF" fails here)';
  }

  final declaredLength = data.getUint32(8, Endian.little);
  if (declaredLength != bytes.lengthInBytes) {
    return 'header declares $declaredLength bytes but the file is '
        '${bytes.lengthInBytes} — truncated or corrupt';
  }

  final jsonChunkLength = data.getUint32(headerLength, Endian.little);
  final jsonChunkType_ = data.getUint32(headerLength + 4, Endian.little);
  if (jsonChunkType_ != jsonChunkType) {
    return 'first chunk is not JSON — malformed GLB';
  }
  if (headerLength + chunkHeaderLength + jsonChunkLength >
      bytes.lengthInBytes) {
    return 'JSON chunk claims $jsonChunkLength bytes, past the end of the file';
  }

  return null;
}

/// Which property a one-finger drag is adjusting. A drag locks to an axis once
/// it clears [kAxisLockSlopPx] and keeps it until the finger lifts, so a
/// slightly diagonal drag cannot flip between resizing and repositioning.
enum GestureAxis { height, position, width }

/// The curtain's live dimensions, in centimetres.
///
/// A value type with the gesture maths as pure functions, so the arithmetic —
/// sensitivity, clamping, limit detection — is testable without a render tree
/// or an AR session.
@immutable
class CurtainMeasurements {
  const CurtainMeasurements({
    required this.widthCm,
    required this.heightCm,
    required this.offsetXCm,
  });

  static const CurtainMeasurements initial = CurtainMeasurements(
    widthCm: kDefaultWidthCm,
    heightCm: kDefaultHeightCm,
    offsetXCm: 0,
  );

  final double widthCm;
  final double heightCm;

  /// Slide along the wall from the anchor. Positive is to the viewer's right.
  final double offsetXCm;

  double get widthM => widthCm / 100;
  double get heightM => heightCm / 100;
  double get offsetXM => offsetXCm / 100;

  bool get atWidthLimit => widthCm <= kMinWidthCm || widthCm >= kMaxWidthCm;
  bool get atHeightLimit => heightCm <= kMinHeightCm || heightCm >= kMaxHeightCm;
  bool get atOffsetLimit => offsetXCm.abs() >= kMaxOffsetCm;

  /// True when any dimension is pinned, used to fire the limit haptic once.
  bool get atAnyLimit => atWidthLimit || atHeightLimit || atOffsetLimit;

  CurtainMeasurements copyWith({
    double? widthCm,
    double? heightCm,
    double? offsetXCm,
  }) => CurtainMeasurements(
    widthCm: widthCm ?? this.widthCm,
    heightCm: heightCm ?? this.heightCm,
    offsetXCm: offsetXCm ?? this.offsetXCm,
  );

  /// Vertical drag. Screen y grows downward, so dragging *up* is a negative
  /// [dyPixels] and must make the curtain taller.
  CurtainMeasurements withHeightDrag(double dyPixels) => copyWith(
    heightCm: (heightCm - dyPixels * kHeightCmPerPixel).clamp(
      kMinHeightCm,
      kMaxHeightCm,
    ),
  );

  /// Horizontal drag. Repositions only — width is untouched.
  CurtainMeasurements withPositionDrag(double dxPixels) => copyWith(
    offsetXCm: (offsetXCm + dxPixels * kOffsetCmPerPixel).clamp(
      -kMaxOffsetCm,
      kMaxOffsetCm,
    ),
  );

  /// Pinch, relative to the width when the gesture began.
  CurtainMeasurements withPinch(double scale) =>
      copyWith(widthCm: (widthCm * scale).clamp(kMinWidthCm, kMaxWidthCm));

  @override
  bool operator ==(Object other) =>
      other is CurtainMeasurements &&
      other.widthCm == widthCm &&
      other.heightCm == heightCm &&
      other.offsetXCm == offsetXCm;

  @override
  int get hashCode => Object.hash(widthCm, heightCm, offsetXCm);

  @override
  String toString() =>
      'width: ${widthCm.toStringAsFixed(1)}cm, '
      'height: ${heightCm.toStringAsFixed(1)}cm, '
      'offsetX: ${offsetXCm.toStringAsFixed(1)}cm';
}

/// Which axis a one-finger drag has committed to, or null while it is still
/// under [kAxisLockSlopPx] and therefore ambiguous.
@visibleForTesting
GestureAxis? axisForDrag(Offset delta) {
  if (delta.distance < kAxisLockSlopPx) return null;
  return delta.dy.abs() > delta.dx.abs()
      ? GestureAxis.height
      : GestureAxis.position;
}

/// True when [next] has pinned a dimension that [previous] had not, i.e. the
/// moment the limit haptic should fire.
///
/// Per dimension on purpose: a single "is anything pinned" flag would swallow
/// the buzz for a height that just bottomed out while the width happened to
/// already be sitting at its maximum.
@visibleForTesting
bool hitLimit(CurtainMeasurements previous, CurtainMeasurements next) =>
    (next.atWidthLimit && !previous.atWidthLimit) ||
    (next.atHeightLimit && !previous.atHeightLimit) ||
    (next.atOffsetLimit && !previous.atOffsetLimit);

/// What a GLB actually contains, read from its JSON chunk.
///
/// Two jobs. It tells you at a glance whether a file is a real model or a
/// placeholder, and its bounding box is the only honest way to pick a scale —
/// glTF carries no unit, so "1.0" means nothing until you know the model is
/// 200 units tall rather than 2.
@immutable
class GlbSummary {
  const GlbSummary({
    required this.meshCount,
    required this.materialCount,
    required this.vertexCount,
    required this.min,
    required this.max,
  });

  final int meshCount;
  final int materialCount;
  final int vertexCount;

  /// Combined bounds over every POSITION accessor, in the file's own units.
  final List<double>? min;
  final List<double>? max;

  double? get width => _span(0);
  double? get height => _span(1);
  double? get depth => _span(2);

  double? _span(int axis) {
    final lo = min;
    final hi = max;
    if (lo == null || hi == null || lo.length < 3 || hi.length < 3) return null;
    return (hi[axis] - lo[axis]).abs();
  }

  /// Multiplier that would make the model [targetHeightM] tall.
  double? suggestedScaleForHeight(double targetHeightM) {
    final h = height;
    if (h == null || h <= 0) return null;
    return targetHeightM / h;
  }

  /// A model with no material cannot render as fabric — glTF's default is flat
  /// untextured white — so that, not polygon count, is the reliable tell. The
  /// Phase 2 rectangle is deliberately four vertices but does carry a material,
  /// and must not trip this.
  bool get looksLikePlaceholder => materialCount == 0 || vertexCount < 4;

  @override
  String toString() {
    final w = width, h = height, d = depth;
    final bounds = (w == null || h == null || d == null)
        ? 'bounds unknown'
        : 'bounds ${w.toStringAsFixed(2)} × ${h.toStringAsFixed(2)} × '
            '${d.toStringAsFixed(2)} (model units)';
    return '$meshCount mesh${meshCount == 1 ? '' : 'es'}, '
        '$materialCount material${materialCount == 1 ? '' : 's'}, '
        '$vertexCount vertices, $bounds';
  }
}

/// Reads the JSON chunk of an already-validated GLB. Returns null if the JSON
/// cannot be parsed — the container check in [glbContainerError] is the gate
/// that matters, this is diagnostics on top.
@visibleForTesting
GlbSummary? glbSummary(Uint8List bytes) {
  try {
    final data = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final jsonLength = data.getUint32(12, Endian.little);
    final jsonBytes = bytes.sublist(20, 20 + jsonLength);
    final decoded = json.decode(utf8.decode(jsonBytes).trim());
    if (decoded is! Map<String, dynamic>) return null;

    final meshes = (decoded['meshes'] as List?) ?? const [];
    final materials = (decoded['materials'] as List?) ?? const [];
    final accessors = (decoded['accessors'] as List?) ?? const [];

    // POSITION accessors are the ones carrying min/max, and glTF requires those
    // bounds on them — so the model's extent is readable without touching the
    // binary chunk.
    final positionIndices = <int>{};
    for (final mesh in meshes) {
      final primitives =
          (mesh is Map ? mesh['primitives'] as List? : null) ?? const [];
      for (final primitive in primitives) {
        if (primitive is! Map) continue;
        final attributes = primitive['attributes'];
        if (attributes is Map && attributes['POSITION'] is int) {
          positionIndices.add(attributes['POSITION'] as int);
        }
      }
    }

    var vertexCount = 0;
    List<double>? min;
    List<double>? max;
    for (final index in positionIndices) {
      if (index < 0 || index >= accessors.length) continue;
      final accessor = accessors[index];
      if (accessor is! Map) continue;
      vertexCount += (accessor['count'] as int?) ?? 0;

      final accessorMin = (accessor['min'] as List?)
          ?.whereType<num>()
          .map((n) => n.toDouble())
          .toList();
      final accessorMax = (accessor['max'] as List?)
          ?.whereType<num>()
          .map((n) => n.toDouble())
          .toList();
      if (accessorMin == null || accessorMax == null) continue;
      if (accessorMin.length < 3 || accessorMax.length < 3) continue;

      min = min == null
          ? accessorMin
          : [for (var i = 0; i < 3; i++) math.min(min[i], accessorMin[i])];
      max = max == null
          ? accessorMax
          : [for (var i = 0; i < 3; i++) math.max(max[i], accessorMax[i])];
    }

    return GlbSummary(
      meshCount: meshes.length,
      materialCount: materials.length,
      vertexCount: vertexCount,
      min: min,
      max: max,
    );
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------- runtime box

/// Builds a GLB for a solid-colour box, in memory.
///
/// Phase 5 asks for a coloured box with no model file and no new packages, and
/// [NodeType] offers only glTF/GLB — the plugin has no primitive geometry and no
/// material API at all. Authoring the container here is the only thing that
/// satisfies all three: nothing ships in `assets/`, nothing is downloaded, and
/// the colour is baked into a real PBR material the native loaders already know
/// how to read.
///
/// 24 vertices rather than 8 so each face carries its own normal; a shared-
/// vertex cube gets smeared lighting along every edge.
@visibleForTesting
Uint8List buildBoxGlb({
  required double width,
  required double height,
  required double depth,
  required Color color,
}) {
  const int glbMagic = 0x46546C67;
  const int jsonChunkType = 0x4E4F534A;
  const int binChunkType = 0x004E4942;
  const int componentFloat = 5126;
  const int componentUnsignedShort = 5123;
  const int targetArrayBuffer = 34962;
  const int targetElementArrayBuffer = 34963;

  final hw = width / 2, hh = height / 2, hd = depth / 2;

  const normalsPerFace = <List<double>>[
    [1, 0, 0],
    [-1, 0, 0],
    [0, 1, 0],
    [0, -1, 0],
    [0, 0, 1],
    [0, 0, -1],
  ];
  // Each face's corners wound counter-clockwise seen from outside, so the box
  // is still right on a renderer that culls back faces.
  final faces = <List<List<double>>>[
    [[hw, -hh, hd], [hw, -hh, -hd], [hw, hh, -hd], [hw, hh, hd]],
    [[-hw, -hh, -hd], [-hw, -hh, hd], [-hw, hh, hd], [-hw, hh, -hd]],
    [[-hw, hh, hd], [hw, hh, hd], [hw, hh, -hd], [-hw, hh, -hd]],
    [[-hw, -hh, -hd], [hw, -hh, -hd], [hw, -hh, hd], [-hw, -hh, hd]],
    [[-hw, -hh, hd], [hw, -hh, hd], [hw, hh, hd], [-hw, hh, hd]],
    [[hw, -hh, -hd], [-hw, -hh, -hd], [-hw, hh, -hd], [hw, hh, -hd]],
  ];

  const int vertexCount = 24;
  const int indexCount = 36;
  const int positionBytes = vertexCount * 3 * 4;
  const int normalBytes = vertexCount * 3 * 4;
  const int indexBytes = indexCount * 2;

  final buffer = ByteData(positionBytes + normalBytes + indexBytes);
  var positionOffset = 0;
  var normalOffset = positionBytes;
  var indexOffset = positionBytes + normalBytes;
  var vertex = 0;

  for (var face = 0; face < faces.length; face++) {
    final firstVertex = vertex;
    for (final corner in faces[face]) {
      for (var axis = 0; axis < 3; axis++) {
        // glTF buffers are little-endian regardless of host.
        buffer.setFloat32(positionOffset, corner[axis], Endian.little);
        buffer.setFloat32(
          normalOffset,
          normalsPerFace[face][axis],
          Endian.little,
        );
        positionOffset += 4;
        normalOffset += 4;
      }
      vertex++;
    }
    for (final corner in <int>[0, 1, 2, 0, 2, 3]) {
      buffer.setUint16(indexOffset, firstVertex + corner, Endian.little);
      indexOffset += 2;
    }
  }

  final json = jsonEncode(<String, dynamic>{
    'asset': {'version': '2.0', 'generator': 'simply_curtains_ar runtime box'},
    'scene': 0,
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'nodes': [
      {'mesh': 0},
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0, 'NORMAL': 1},
            'indices': 2,
            'material': 0,
          },
        ],
      },
    ],
    'materials': [
      {
        'name': 'swatch',
        'pbrMetallicRoughness': {
          'baseColorFactor': _baseColorFactor(color),
          'metallicFactor': 0.0,
          // Fabric is matte. A glossy panel reads as plastic and picks up
          // highlights that fight the camera feed.
          'roughnessFactor': 0.9,
        },
        // The user can walk behind the panel; culling would make it vanish.
        'doubleSided': true,
      },
    ],
    'accessors': [
      {
        'bufferView': 0,
        'componentType': componentFloat,
        'count': vertexCount,
        'type': 'VEC3',
        // Required by the spec on POSITION, and the bounds Phase 3's inspector
        // reads back to work out the model's real-world size.
        'min': [-hw, -hh, -hd],
        'max': [hw, hh, hd],
      },
      {
        'bufferView': 1,
        'componentType': componentFloat,
        'count': vertexCount,
        'type': 'VEC3',
      },
      {
        'bufferView': 2,
        'componentType': componentUnsignedShort,
        'count': indexCount,
        'type': 'SCALAR',
      },
    ],
    'bufferViews': [
      {
        'buffer': 0,
        'byteOffset': 0,
        'byteLength': positionBytes,
        'target': targetArrayBuffer,
      },
      {
        'buffer': 0,
        'byteOffset': positionBytes,
        'byteLength': normalBytes,
        'target': targetArrayBuffer,
      },
      {
        'buffer': 0,
        'byteOffset': positionBytes + normalBytes,
        'byteLength': indexBytes,
        'target': targetElementArrayBuffer,
      },
    ],
    'buffers': [
      {'byteLength': buffer.lengthInBytes},
    ],
  });

  // Both chunks must end on a 4-byte boundary: JSON pads with spaces, BIN with
  // zeros. Loaders reject a GLB whose chunk lengths do not line up.
  final jsonBytes = utf8.encode(json);
  final jsonPadding = (4 - jsonBytes.length % 4) % 4;
  final binBytes = buffer.buffer.asUint8List();
  final binPadding = (4 - binBytes.length % 4) % 4;

  const headerLength = 12;
  const chunkHeaderLength = 8;
  final totalLength = headerLength +
      chunkHeaderLength +
      jsonBytes.length +
      jsonPadding +
      chunkHeaderLength +
      binBytes.length +
      binPadding;

  final out = BytesBuilder(copy: false);
  final header = ByteData(headerLength)
    ..setUint32(0, glbMagic, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, totalLength, Endian.little);
  out.add(header.buffer.asUint8List());

  final jsonHeader = ByteData(chunkHeaderLength)
    ..setUint32(0, jsonBytes.length + jsonPadding, Endian.little)
    ..setUint32(4, jsonChunkType, Endian.little);
  out.add(jsonHeader.buffer.asUint8List());
  out.add(jsonBytes);
  out.add(Uint8List.fromList(List<int>.filled(jsonPadding, 0x20)));

  final binHeader = ByteData(chunkHeaderLength)
    ..setUint32(0, binBytes.length + binPadding, Endian.little)
    ..setUint32(4, binChunkType, Endian.little);
  out.add(binHeader.buffer.asUint8List());
  out.add(binBytes);
  out.add(Uint8List.fromList(List<int>.filled(binPadding, 0)));

  return out.takeBytes();
}

/// glTF's `baseColorFactor` is linear, Flutter's [Color] is sRGB. Skipping the
/// transfer-function conversion is why hand-written glTF colours come out
/// looking washed out next to the swatch that produced them.
List<double> _baseColorFactor(Color color) => <double>[
      _srgbToLinear(color.r),
      _srgbToLinear(color.g),
      _srgbToLinear(color.b),
      color.a,
    ];

double _srgbToLinear(double channel) => channel <= 0.04045
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

/// Transient "that tap did not land on a wall" feedback. Value type so the
/// notifier can skip identical updates.
@immutable
class _Hint {
  const _Hint(this.message, [this.detail]);

  final String message;
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is _Hint && other.message == message && other.detail == detail;

  @override
  int get hashCode => Object.hash(message, detail);
}

// ----------------------------------------------------------------- geometry

/// Orientation of the placement rectangle **relative to its anchor**.
///
/// For a plane hit both platforms hand back a pose whose local +Y is the
/// surface normal, and the quad is authored facing +Z, so lying it flat against
/// a wall is the -π/2 rotation about X that the phase-2 brief calls for. That
/// shortcut only holds if the platform's in-plane X axis lands where you expect
/// it, and ARCore and ARKit do not agree on that — so the basis is built
/// explicitly in world space and then expressed in anchor space. For a wall it
/// reduces to exactly R_x(-π/2) whatever the in-plane axis; for a floor or
/// table it instead stands the rectangle upright, because a curtain hangs plumb
/// whatever it happened to be anchored to.
///
/// Exercised by test/orientation_test.dart.
vm.Quaternion rectRotationForHit(
  vm.Matrix4 hitTransform,
  vm.Vector3? cameraPosition,
) {
  final anchorBasis = orthonormalBasis(hitTransform);
  final normal = anchorBasis.getColumn(1).normalized();
  final hitPosition = hitTransform.getTranslation();
  final worldUp = vm.Vector3(0, 1, 0);
  final worldForward = vm.Vector3(0, 0, 1);

  // The rectangle's own axes, in world space.
  final vm.Vector3 forward; // +Z, the face turned towards the room
  final vm.Vector3 up; // +Y, the direction the fabric hangs from

  if (normal.y.abs() < kVerticalNormalTolerance) {
    // Wall: sit flush against it, facing out along its normal.
    forward = normal;
    var projectedUp = worldUp - normal * worldUp.dot(normal);
    if (projectedUp.length2 < 1e-6) projectedUp = worldUp;
    up = projectedUp.normalized();
  } else {
    // Floor or ceiling: standing the quad up matters more than matching the
    // surface, so face it at the camera instead. Unreachable with
    // [kPlaneDetectionConfig] set to vertical, but kept so a config change
    // cannot silently lay curtains on the floor.
    up = worldUp;
    var toCamera = (cameraPosition ?? hitPosition + worldForward) - hitPosition;
    toCamera = vm.Vector3(toCamera.x, 0, toCamera.z);
    if (toCamera.length2 < 1e-6) toCamera = worldForward;
    forward = toCamera.normalized();
  }

  final right = up.cross(forward); // right-handed: x = y × z
  final worldRotation = vm.Matrix3.columns(right, up, forward);

  // R_local = R_anchor⁻¹ · R_world, and an orthonormal basis inverts by
  // transpose.
  final localRotation = anchorBasis.transposed()..multiply(worldRotation);
  return vm.Quaternion.fromRotation(localRotation)..normalize();
}

/// Rotation part of [matrix] with each basis column renormalised, so downstream
/// transposes really are inverses.
vm.Matrix3 orthonormalBasis(vm.Matrix4 matrix) {
  final rotation = matrix.getRotation();
  return vm.Matrix3.columns(
    rotation.getColumn(0).normalized(),
    rotation.getColumn(1).normalized(),
    rotation.getColumn(2).normalized(),
  );
}

/// True when the hit landed on a wall rather than a floor, ceiling or table.
bool isVerticalSurface(vm.Matrix4 hitTransform) =>
    orthonormalBasis(hitTransform).getColumn(1).normalized().y.abs() <
    kVerticalNormalTolerance;

/// Motion bucket for the current sample, with hysteresis around each boundary
/// so a phone hovering near a threshold does not oscillate.
MotionState classifyMotion(
  double gyroMagnitude,
  double accelMagnitude,
  MotionState current,
) {
  final tooFastLimit =
      current == MotionState.tooFast ? kTooFastExit : kTooFastEnter;
  if (gyroMagnitude > tooFastLimit) return MotionState.tooFast;

  final stillGyroLimit =
      current == MotionState.still ? kStillGyroExit : kStillGyroEnter;
  final stillAccelLimit =
      current == MotionState.still ? kStillAccelExit : kStillAccelEnter;
  if (gyroMagnitude < stillGyroLimit && accelMagnitude < stillAccelLimit) {
    return MotionState.still;
  }
  return MotionState.good;
}

class ArScreen extends StatefulWidget {
  const ArScreen({super.key});

  @override
  State<ArScreen> createState() => _ArScreenState();
}

class _ArScreenState extends State<ArScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  ARSessionManager? _arSessionManager;
  ARObjectManager? _arObjectManager;
  ARAnchorManager? _arAnchorManager;

  /// `setState` is reserved for the three whole-screen modes below. Everything
  /// that changes while the AR session is live goes through a [ValueNotifier]
  /// instead, so a sensor sample or a timer tick repaints one leaf widget
  /// rather than rebuilding the platform view and every overlay.
  _PermissionState _permission = _PermissionState.checking;
  String? _arError;

  /// Built once in [initState]. Reusing the identical widget instance makes
  /// `Element.updateChild` short-circuit, so the AR platform view subtree is
  /// never rebuilt or diffed no matter what else changes.
  late final Widget _arSurface;

  final ValueNotifier<int> _planeCount = ValueNotifier<int>(0);
  final ValueNotifier<bool> _showSurfaceFoundToast = ValueNotifier<bool>(false);
  final ValueNotifier<int> _scanSeconds = ValueNotifier<int>(0);
  final ValueNotifier<MotionState> _motion =
      ValueNotifier<MotionState>(MotionState.still);
  final ValueNotifier<bool> _trackingLost = ValueNotifier<bool>(false);
  final ValueNotifier<_Hint?> _hint = ValueNotifier<_Hint?>(null);
  final ValueNotifier<bool> _hasPlacement = ValueNotifier<bool>(false);

  Timer? _scanTimer;

  double _gyroMagnitude = 0;
  double _accelMagnitude = 0;

  // ------------------------------------------------------------- placement

  /// Filenames passed to the plugin, relative to the app documents directory,
  /// keyed by swatch id. One file per colour — see [_stagePanel].
  final Map<String, String> _panelUris = <String, String>{};

  /// Swatches whose renderable the device refused. Checked before a swap so a
  /// bad colour reports instead of leaving the wall empty.
  final Set<String> _warmUpFailures = <String>{};

  /// The colour the panel is currently wearing.
  Swatch _selectedSwatch = kSwatches.first;

  /// The palette slides up once there is something to recolour.
  bool _swatchSelectorVisible = false;

  /// Where the last screenshot was written, for the capture dialog.
  String? _screenshotPath;

  final ValueNotifier<ModelLoadState> _modelState =
      ValueNotifier<ModelLoadState>(ModelLoadState.loading);

  /// True once the curtain's renderable has actually been compiled by the
  /// native renderer, not merely copied to disk. See [_warmUpCurtain].
  bool get _modelPreloaded => _modelState.value != ModelLoadState.loading;

  /// Completes when staging has settled, so a tap that lands mid-preload can
  /// await it rather than dropping.
  Future<void>? _preload;

  /// Shown while a tap is waiting on a preload that has not finished.
  final ValueNotifier<bool> _awaitingModel = ValueNotifier<bool>(false);

  /// Live dimensions, driven by the resize gestures.
  final ValueNotifier<CurtainMeasurements> _measurements =
      ValueNotifier<CurtainMeasurements>(CurtainMeasurements.initial);

  /// Shown for [kInstructionOverlayDuration] after the first placement.
  final ValueNotifier<bool> _showInstructions = ValueNotifier<bool>(false);
  bool _instructionsShown = false;
  Timer? _instructionTimer;

  // --------------------------------------------------------------- gestures

  /// Snapshot taken when a gesture begins; every update is computed from this
  /// rather than accumulated, so clamping is reversible — drag back out of a
  /// limit and the curtain follows instead of sticking.
  CurtainMeasurements _measurementsAtGestureStart =
      CurtainMeasurements.initial;
  GestureAxis? _gestureAxis;
  Offset _gestureStartFocal = Offset.zero;

  /// Focal point at the moment the axis locked, so the [kAxisLockSlopPx] dead
  /// zone is not also applied as a jump.
  Offset _axisAnchorFocal = Offset.zero;

  /// Free-running monotonic clock for throttling gesture-driven transform
  /// writes. Separate from [_animationClock], which is reset per pop-in.
  final Stopwatch _gestureClock = Stopwatch()..start();
  Duration _lastGestureWrite = Duration.zero;

  ARPlaneAnchor? _placedAnchor;
  ARNode? _placedNode;
  vm.Vector3? _placementPosition;

  /// The full hit pose the panel was anchored on. A colour change re-anchors at
  /// exactly this transform, so the panel does not shift when it is swapped.
  vm.Matrix4? _placementTransform;

  /// True once a panel is on the wall — gates the camera button and palette.
  final ValueNotifier<bool> _boxPlaced = ValueNotifier<bool>(false);

  /// Drives the shutter flash and the saved-shot thumbnail.
  final ValueNotifier<bool> _shutterFlash = ValueNotifier<bool>(false);
  final ValueNotifier<Uint8List?> _thumbnail = ValueNotifier<Uint8List?>(null);
  Timer? _thumbnailTimer;
  bool _isCapturing = false;
  bool _isSwappingSwatch = false;

  /// The model's orientation *relative to its anchor*, held so every animation
  /// frame can recompose the same pose at a new scale.
  vm.Quaternion? _nodeRotation;

  int _placementCount = 0;
  bool _isPlacing = false;

  late final AnimationController _scaleController;
  Duration _lastTransformWrite = Duration.zero;
  final Stopwatch _animationClock = Stopwatch();

  Timer? _hintTimer;

  // -------------------------------------------------------------- tracking

  Timer? _poseTimer;
  vm.Vector3? _lastCameraPosition;
  vm.Vector3? _lastLoggedCameraPosition;
  int _trackingStrikes = 0;

  /// Set once the session has produced a camera pose at least once.
  bool _trackingEstablished = false;

  /// Sensors and polling idle while the app is backgrounded — the AR session is
  /// not producing frames, so every poll is a wasted channel round trip.
  bool _isResumed = true;

  Offset? _tapDownPosition;
  DateTime? _tapDownTime;
  Timer? _missTimer;

  /// Tap arbitration state. See [_handleTap] for why a plane hit cannot always
  /// be acted on the moment the native side reports it.
  bool _pointerIsDown = false;
  bool _tapDisqualified = false;
  ARHitTestResult? _pendingPlacementHit;

  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  StreamSubscription<UserAccelerometerEvent>? _accelSubscription;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scaleController = AnimationController(
      vsync: this,
      duration: kPlacementAnimDuration,
    )..addListener(_applyScaleFrame);

    // Layered deliberately:
    //  * RepaintBoundary keeps overlay repaints off the camera texture.
    //  * GestureDetector runs the resize gestures. Only the scale callbacks
    //    are used — Flutter rejects a pan recognizer alongside a scale one,
    //    and ScaleGestureRecognizer already reports one-finger drags through
    //    focalPoint. It stays out of the way of a clean tap: with no movement
    //    it never reaches its started state, loses the arena, and the platform
    //    view gets the touch and runs its own hit test.
    //  * Listener never enters the arena at all, so it observes every pointer
    //    regardless of who wins — which is what lets [_onPointerUp] decide
    //    whether a native hit was a tap or the start of a drag.
    _arSurface = RepaintBoundary(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: ARView(
            onARViewCreated: _onArViewCreated,
            planeDetectionConfig: kPlaneDetectionConfig,
          ),
        ),
      ),
    );

    _resolveCameraPermission();
    _listenToMotionSensors();
    // Stage both models up front so the first tap pays for neither.
    _preload = _preloadModels();
    unawaited(_preload);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gyroSubscription?.cancel();
    _accelSubscription?.cancel();
    _toastTimer?.cancel();
    _scanTimer?.cancel();
    _hintTimer?.cancel();
    _missTimer?.cancel();
    _poseTimer?.cancel();
    _scaleController.dispose();
    _planeCount.dispose();
    _showSurfaceFoundToast.dispose();
    _scanSeconds.dispose();
    _motion.dispose();
    _trackingLost.dispose();
    _hint.dispose();
    _hasPlacement.dispose();
    _modelState.dispose();
    _awaitingModel.dispose();
    _measurements.dispose();
    _showInstructions.dispose();
    _instructionTimer?.cancel();
    _thumbnailTimer?.cancel();
    _boxPlaced.dispose();
    _shutterFlash.dispose();
    _thumbnail.dispose();
    _arSessionManager?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isResumed = state == AppLifecycleState.resumed;
    if (_isResumed) {
      if (_arSessionManager != null) _startPosePolling();
    } else {
      _poseTimer?.cancel();
      _poseTimer = null;
    }
  }

  // ---------------------------------------------------------------- permission

  Future<void> _resolveCameraPermission() async {
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      status = await Permission.camera.request();
    }
    if (!mounted) return;
    final granted = status.isGranted;
    setState(() {
      _permission =
          granted ? _PermissionState.granted : _PermissionState.denied;
    });
    if (granted) _startScanTimer();
  }

  void _startScanTimer() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_planeCount.value > 0) {
        _scanTimer?.cancel();
        return;
      }
      _scanSeconds.value++;
    });
  }

  // ------------------------------------------------------------------- motion

  /// Gyroscope catches rotation, user-accelerometer catches translation. A user
  /// sweeping the phone sideways may barely rotate it, so both are needed to
  /// tell "actually scanning" from "holding it dead still".
  void _listenToMotionSensors() {
    _gyroSubscription = gyroscopeEventStream().listen((event) {
      _gyroMagnitude = math.sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      _updateMotionState();
    });
    _accelSubscription = userAccelerometerEventStream().listen((event) {
      _accelMagnitude = math.sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      _updateMotionState();
    });
  }

  void _updateMotionState() {
    if (!_isResumed) return;
    // Assigning an unchanged value to a ValueNotifier is a no-op, so a steady
    // hand costs nothing at all.
    _motion.value =
        classifyMotion(_gyroMagnitude, _accelMagnitude, _motion.value);
  }

  // ------------------------------------------------------------------ session

  void _onArViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    _arSessionManager = arSessionManager;
    _arObjectManager = arObjectManager;
    _arAnchorManager = arAnchorManager;

    arSessionManager.onError = _handleArError;
    arSessionManager.onPlaneDetected = _handlePlaneDetected;
    arSessionManager.onPlaneOrPointTap = _handleTap;

    try {
      arSessionManager.onInitialize(
        showAnimatedGuide: false,
        showFeaturePoints: kShowFeaturePoints,
        showPlanes: true,
        // Without this the detected walls are effectively invisible — see
        // [kPlaneTextureAssetPath].
        customPlaneTexturePath: kPlaneTextureAssetPath,
        showWorldOrigin: false,
        handleTaps: true,
      );
      arObjectManager.onInitialize();
      _startPosePolling();
      // Compiling the curtain's renderable needs a live session, so the second
      // half of the preload can only start here.
      unawaited(_preload?.then((_) => _warmUpPanels()));
    } catch (e) {
      _handleArError('AR session failed to initialize: $e');
    }
  }

  void _handleArError(String error) {
    debugPrint('AR ERROR → $error');
    if (!mounted) return;
    setState(() => _arError = error);
  }

  /// The plugin reports the running total of planes only — no per-plane id or
  /// type, and no separate "updated" channel. With [kPlaneDetectionConfig] set
  /// to vertical, every plane counted here is a wall.
  void _handlePlaneDetected(int planeCount) {
    final isFirstPlane = _planeCount.value == 0;
    debugPrint(
      'WALL DETECTED → total walls: $planeCount, after ${_scanSeconds.value}s',
    );

    if (planeCount > _planeCount.value) _planeCount.value = planeCount;

    if (isFirstPlane) {
      _scanTimer?.cancel();
      _toastTimer?.cancel();
      _showSurfaceFoundToast.value = true;
      _toastTimer = Timer(kSurfaceFoundToastDuration, () {
        _showSurfaceFoundToast.value = false;
      });
    }
  }

  // --------------------------------------------------------------- tap input

  void _onPointerDown(PointerDownEvent event) {
    _tapDownPosition = event.position;
    _tapDownTime = DateTime.now();
    _pointerIsDown = true;
    _tapDisqualified = false;
    _pendingPlacementHit = null;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final downPosition = _tapDownPosition;
    if (downPosition == null || _tapDisqualified) return;
    if ((event.position - downPosition).distance > kTapSlopPx) {
      _tapDisqualified = true;
      _pendingPlacementHit = null;
      _missTimer?.cancel();
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final downPosition = _tapDownPosition;
    final downTime = _tapDownTime;
    _pointerIsDown = false;
    _tapDownPosition = null;
    _tapDownTime = null;

    final qualified =
        downPosition != null &&
        downTime != null &&
        !_tapDisqualified &&
        (event.position - downPosition).distance <= kTapSlopPx &&
        DateTime.now().difference(downTime) <= kTapMaxDuration;

    if (!qualified) {
      _pendingPlacementHit = null;
      _missTimer?.cancel();
      return;
    }

    // Android reported its hit back on ACTION_DOWN; now that the sequence has
    // proved to be a tap rather than the start of a drag, honour it.
    final pending = _pendingPlacementHit;
    _pendingPlacementHit = null;
    if (pending != null) {
      unawaited(_placeCurtain(pending));
      return;
    }

    _missTimer?.cancel();
    _missTimer = Timer(kTapMissTimeout, () {
      _showHint(const _Hint('Tap directly on the highlighted wall'));
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerIsDown = false;
    _tapDownPosition = null;
    _tapDownTime = null;
    _tapDisqualified = true;
    _pendingPlacementHit = null;
    _missTimer?.cancel();
  }

  void _handleTap(List<ARHitTestResult> hits) {
    _missTimer?.cancel();

    ARHitTestResult? planeHit;
    ARHitTestResult? pointHit;
    ARHitTestResult? edgeHit;
    for (final hit in hits) {
      switch (hit.type) {
        case ARHitTestResultType.plane:
          planeHit ??= hit;
        case ARHitTestResultType.point:
          pointHit ??= hit;
        case ARHitTestResultType.undefined:
          // Android marks a hit `undefined` when the ray met a tracked plane
          // but landed outside its polygon (Serializers.kt:14 gates type 1 on
          // `isPoseInPolygon`). Discarding these silently is why a tap near a
          // wall could look like it did nothing at all.
          edgeHit ??= hit;
      }
    }

    debugPrint(
      'TAP → ${hits.length} hit(s): '
      '${hits.map((h) => '${h.type.name}@${h.distance.toStringAsFixed(2)}m').join(', ')}',
    );

    if (planeHit != null) {
      // Android raises this from ACTION_DOWN, before it can possibly know
      // whether the finger is about to drag. Committing here would re-place
      // the curtain at the start of every resize gesture, so the hit is held
      // until the pointer lifts and proves it was a tap. iOS raises it from a
      // UITapGestureRecognizer, i.e. after the lift, so there is nothing left
      // to wait for and it is placed straight away.
      if (_pointerIsDown) {
        _pendingPlacementHit = planeHit;
      } else if (!_tapDisqualified) {
        unawaited(_placeCurtain(planeHit));
      }
      return;
    }

    if (edgeHit != null) {
      _showHint(
        _Hint(
          'Just outside the detected area',
          'That is ${edgeHit.distance.toStringAsFixed(2)} m away but past the '
              'edge of the wall the app has mapped. Aim inside the highlight, '
              'or sweep the wall to grow it.',
        ),
      );
      return;
    }

    _showHint(
      _Hint(
        'Tap directly on the highlighted wall',
        pointHit == null
            ? 'Nothing tracked under that tap yet.'
            : 'Tracked texture at ${pointHit.distance.toStringAsFixed(2)} m, '
                'but no wall surface there yet.',
      ),
    );
  }

  void _showHint(_Hint hint) {
    _hint.value = hint;
    _hintTimer?.cancel();
    _hintTimer = Timer(kPlacementHintDuration, () => _hint.value = null);
  }

  // -------------------------------------------------------------- placement

  /// Writes the runtime-authored panel for [swatch] into the app documents
  /// directory and validates it, returning the filename to hand [ARNode].
  ///
  /// One file per colour, and the filename must differ per colour: Android
  /// caches renderables under `ModelRenderable.setRegistryId(modelPath)`, so
  /// reusing a single `panel.glb` would serve the *previously compiled* colour
  /// forever and the swatch would appear to do nothing.
  ///
  /// A malformed model is an expected condition, not an exceptional one, so it
  /// comes back as a value. Throwing across the preload's async boundary also
  /// escapes into the zone before the caller's handler runs, which turns a
  /// handled failure into an unhandled error report.
  Future<({String? uri, String? error})> _stagePanel(Swatch swatch) async {
    try {
      final bytes = buildBoxGlb(
        width: kNominalModelWidthM,
        height: kNominalModelHeightM,
        depth: kPanelDepthM,
        color: swatch.color,
      );

      // The generator is ours, but a container error here would surface on the
      // device as an opaque "Unable to load renderable", so it is still checked.
      final containerError = glbContainerError(bytes);
      if (containerError != null) {
        return (
          uri: null,
          error: 'generated panel for ${swatch.id} is malformed: $containerError',
        );
      }

      final fileName = 'panel_${swatch.id}.glb';
      final directory = await getApplicationDocumentsDirectory();
      await File('${directory.path}/$fileName').writeAsBytes(bytes, flush: true);
      _reportPanelContents(swatch, bytes);
      return (uri: fileName, error: null);
    } catch (e) {
      return (uri: null, error: 'could not stage panel for ${swatch.id}: $e');
    }
  }

  /// Logs what the generated panel actually contains. glTF stores no unit, so
  /// this is the only way to turn "the panel looks tiny" into a number.
  void _reportPanelContents(Swatch swatch, Uint8List bytes) {
    final summary = glbSummary(bytes);
    if (summary == null) {
      debugPrint('GLB INSPECT → panel_${swatch.id}: container valid, JSON '
          'unreadable');
      return;
    }
    debugPrint('GLB INSPECT → panel_${swatch.id} (${swatch.hex}): $summary');
  }

  /// Stages every swatch up front so a colour change is a node swap rather than
  /// a file write plus a compile.
  Future<void> _preloadModels() async {
    // Concurrent: four independent files, and doing them in series put four
    // documents-directory round trips on the critical path before the first
    // tap could place anything.
    final staged = await Future.wait(kSwatches.map(_stagePanel));
    for (var i = 0; i < kSwatches.length; i++) {
      final result = staged[i];
      if (result.uri != null) {
        _panelUris[kSwatches[i].id] = result.uri!;
      } else {
        debugPrint('PANEL STAGE FAILED → ${result.error}');
      }
    }

    if (_panelUris[_selectedSwatch.id] == null) {
      _failToLoad('no panel could be generated for ${_selectedSwatch.name}');
      return;
    }

    // The renderable is not compiled until a node using it is added, so staging
    // alone does not make the first tap fast. [_warmUpPanels] does that, and it
    // needs a live session — it runs from _onArViewCreated.
    if (_arObjectManager != null) await _warmUpPanels();
  }

  /// Forces the native renderer to build each panel's renderable, by adding an
  /// un-anchored node at a negligible scale and removing it again.
  ///
  /// This is what makes the preload real. Android caches by registry id and iOS
  /// parses the file into an `SCNScene`, so the expensive work happens here
  /// instead of on the user's first tap — and, because every colour is warmed,
  /// a swatch swap later costs only the node exchange. Removing an un-anchored
  /// node is reliable on both platforms: its parent *is* the scene root, which
  /// is exactly what `removeNode` operates on.
  Future<void> _warmUpPanels() async {
    final objectManager = _arObjectManager;
    if (objectManager == null) return;
    if (_modelState.value != ModelLoadState.loading) return;

    for (final swatch in kSwatches) {
      final uri = _panelUris[swatch.id];
      if (uri == null) continue;

      final probe = ARNode(
        type: NodeType.fileSystemAppFolderGLB,
        uri: uri,
        name: '[#panel_warmup_${swatch.id}]',
        transformation: vm.Matrix4.compose(
          vm.Vector3.zero(),
          vm.Quaternion.identity(),
          vm.Vector3.all(kMinPlacementScale),
        ),
      );

      bool? added;
      Object? failure;
      try {
        added = await objectManager.addNode(probe);
      } catch (e) {
        failure = e;
      } finally {
        objectManager.removeNode(probe);
      }

      // Only the colour the panel is placed in has to compile for the session
      // to be usable; a later swatch that will not load is reported when it is
      // actually chosen.
      if ((failure != null || added != true) && swatch == _selectedSwatch) {
        _failToLoad(
          'the native renderer rejected the generated panel '
          '(unsupported geometry or an unreadable file)'
          '${failure == null ? '' : ': $failure'}',
        );
        return;
      }
      if (failure != null || added != true) {
        _warmUpFailures.add(swatch.id);
        debugPrint('PANEL WARMUP → ${swatch.name} did not compile');
      }
    }

    debugPrint('GLB LOADED → preload complete (${_panelUris.length} panels)');
    _modelState.value = ModelLoadState.ready;
  }

  /// The panel could not be built or compiled. Say so loudly rather than
  /// silently showing nothing at all.
  void _failToLoad(String reason) {
    debugPrint('GLB LOAD FAILED → $reason');
    if (!mounted || _modelState.value == ModelLoadState.fallback) return;
    _modelState.value = ModelLoadState.fallback;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: const Text('Could not build the panel for this device'),
        ),
      );
    });
  }

  /// The uri a placement should use right now.
  String? get _activeModel => _panelUris[_selectedSwatch.id];

  Future<void> _placeCurtain(ARHitTestResult hit) async {
    final objectManager = _arObjectManager;
    final anchorManager = _arAnchorManager;
    if (objectManager == null || anchorManager == null || _isPlacing) return;

    _isPlacing = true;
    try {
      // Tapped before the preload finished: show the spinner and wait rather
      // than dropping the tap.
      if (!_modelPreloaded) {
        _awaitingModel.value = true;
        try {
          await _preload;
          await _warmUpPanels();
        } finally {
          _awaitingModel.value = false;
        }
      }

      final modelUri = _activeModel;
      if (modelUri == null) {
        _showHint(const _Hint('Could not load the placement model'));
        return;
      }

      // One curtain at a time: the previous anchor goes before the new one.
      _clearPlacement();

      final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      final anchorAdded = await anchorManager.addAnchor(anchor);
      if (anchorAdded != true) {
        _showHint(const _Hint('Could not anchor there — try another spot'));
        return;
      }

      // Same orientation maths as the Phase 2 rectangle: the curtain has to
      // hang plumb against the wall, never lie flat.
      _nodeRotation = rectRotationForHit(
        hit.worldTransform,
        _lastCameraPosition,
      );
      _placementCount++;

      final node = ARNode(
        type: NodeType.fileSystemAppFolderGLB,
        uri: modelUri,
        // iOS walks up from a tapped SCNNode looking for a parent whose name
        // starts with "[#", so the prefix has to survive our custom naming.
        name: '[#curtain_$_placementCount]',
        transformation: _nodeTransform(0),
      );

      final nodeAdded = await objectManager.addNode(node, planeAnchor: anchor);
      if (nodeAdded != true) {
        anchorManager.removeAnchor(anchor);
        _failToLoad('addNode rejected the generated panel at placement time');
        _showHint(const _Hint('Could not place there — try another spot'));
        return;
      }

      _placedAnchor = anchor;
      _placedNode = node;
      _placementPosition = hit.worldTransform.getTranslation();
      // Kept whole, not just the translation: a colour swap re-anchors on this
      // exact pose so the panel does not shift when it changes.
      _placementTransform = hit.worldTransform.clone();
      _lastLoggedCameraPosition = _lastCameraPosition;

      // Not awaited: the haptic should land with the pop-in, not before it.
      unawaited(HapticFeedback.mediumImpact());
      _lastTransformWrite = Duration.zero;
      _animationClock
        ..reset()
        ..start();
      _scaleController.forward(from: 0);

      final p = _placementPosition!;
      final s = _nodeScale(1);
      debugPrint(
        'GLB PLACED → position: [${p.x.toStringAsFixed(3)}, '
        '${p.y.toStringAsFixed(3)}, ${p.z.toStringAsFixed(3)}], '
        'scale: [${s.x.toStringAsFixed(3)}, ${s.y.toStringAsFixed(3)}, '
        '${s.z.toStringAsFixed(3)}], ${_measurements.value}',
      );
      final m = _measurements.value;
      debugPrint(
        'BOX PLACED → pos: [${p.x.toStringAsFixed(3)},${p.y.toStringAsFixed(3)},'
        '${p.z.toStringAsFixed(3)}], size: '
        '${m.widthM.toStringAsFixed(2)}×${m.heightM.toStringAsFixed(2)}×'
        '${kPanelDepthM.toStringAsFixed(2)}m, colour: $_selectedSwatch',
      );
      debugPrint(
        'GLB PLACED → anchor type: ${anchor.type.name}, '
        'hit ${hit.type.name} at ${hit.distance.toStringAsFixed(2)} m, '
        '${isVerticalSurface(hit.worldTransform) ? 'vertical — flush to the wall' : 'horizontal — standing upright'}',
      );

      _hint.value = null;
      _hasPlacement.value = true;
      _boxPlaced.value = true;
      if (!_swatchSelectorVisible) {
        setState(() => _swatchSelectorVisible = true);
      }
      _showGestureInstructionsOnce();
    } finally {
      _isPlacing = false;
    }
  }

  // ------------------------------------------------------------- swatches

  /// Recolours the placed panel.
  ///
  /// There is no material API to reach for: [ARNode] carries a uri and a
  /// transform and nothing else, and the plugin exposes no way to touch a
  /// loaded model's materials on either platform. So the colour lives in the
  /// model, and changing it means exchanging the node.
  ///
  /// The anchor goes with it. Android's `removeNode` calls
  /// `scene.removeChild(node)`, but an anchored node's parent is the AnchorNode
  /// rather than the scene, so removing the node alone silently does nothing
  /// there and would leave two panels stacked on the wall. Re-anchoring on the
  /// stored placement transform puts the replacement in exactly the same pose.
  ///
  /// Both panels are already compiled by [_warmUpPanels], so the exchange is
  /// two channel round trips rather than a model load — but it is not free, and
  /// the elapsed time is measured and logged so Phase 5 can judge the hitch.
  Future<void> _applySwatch(Swatch swatch) async {
    if (_isSwappingSwatch) return;

    final previous = _selectedSwatch;
    setState(() => _selectedSwatch = swatch);

    if (!_hasPlacement.value) {
      // Nothing on the wall yet — the choice just seeds the next placement.
      debugPrint('SWATCH → ${swatch.name}, color applied: pending placement');
      return;
    }

    final objectManager = _arObjectManager;
    final anchorManager = _arAnchorManager;
    final transform = _placementTransform;
    final uri = _panelUris[swatch.id];

    if (objectManager == null ||
        anchorManager == null ||
        transform == null ||
        uri == null ||
        _warmUpFailures.contains(swatch.id)) {
      setState(() => _selectedSwatch = previous);
      debugPrint('SWATCH → ${swatch.name}, color applied: failed');
      _reportSwatchUnsupported();
      return;
    }

    _isSwappingSwatch = true;
    final stopwatch = Stopwatch()..start();
    try {
      // Drop the old anchor first: on Android this is the only teardown that
      // actually removes an anchored node.
      final oldAnchor = _placedAnchor;
      if (oldAnchor != null) anchorManager.removeAnchor(oldAnchor);
      _placedAnchor = null;
      _placedNode = null;

      final anchor = ARPlaneAnchor(transformation: transform);
      if (await anchorManager.addAnchor(anchor) != true) {
        throw StateError('re-anchoring for the colour change was refused');
      }

      _placementCount++;
      final node = ARNode(
        type: NodeType.fileSystemAppFolderGLB,
        uri: uri,
        name: '[#curtain_$_placementCount]',
        // Full size straight away: the panel was already on the wall, so
        // replaying the pop-in would read as a glitch rather than a placement.
        transformation: _nodeTransform(1),
      );

      if (await objectManager.addNode(node, planeAnchor: anchor) != true) {
        anchorManager.removeAnchor(anchor);
        throw StateError('the device would not render ${swatch.name}');
      }

      _placedAnchor = anchor;
      _placedNode = node;
      stopwatch.stop();

      debugPrint('SWATCH → ${swatch.name}, color applied: success '
          '(${swatch.hex}, ${stopwatch.elapsedMilliseconds}ms)');
      if (stopwatch.elapsedMilliseconds > kSwatchSwapFlickerMs) {
        debugPrint('FLICKER DETECTED');
        debugPrint('FLICKER → color swap caused '
            '${stopwatch.elapsedMilliseconds}ms freeze');
      }
    } catch (e) {
      stopwatch.stop();
      debugPrint('SWATCH → ${swatch.name}, color applied: failed ($e)');
      // The wall is empty at this point, so the session has to be honest about
      // it rather than leave the user staring at nothing.
      setState(() => _selectedSwatch = previous);
      _clearPlacement();
      _boxPlaced.value = false;
      _reportSwatchUnsupported();
    } finally {
      _isSwappingSwatch = false;
    }
  }

  // ----------------------------------------------------------- screenshot

  /// Captures the AR scene and puts it in the device gallery.
  ///
  /// The plugin's API is `ARSessionManager.snapshot()`, which hands back an
  /// `ImageProvider` rather than bytes — it wraps the PNG the native side
  /// produced in a [MemoryImage], so the bytes come back off that.
  ///
  /// Saving goes through `gal`, not `image_gallery_saver`: the latter is
  /// unbuildable against the v2 Android embedding (it still references
  /// `PluginRegistry.Registrar`), which is why it was replaced in pubspec.
  Future<void> _captureScreenshot() async {
    final session = _arSessionManager;
    if (session == null || _isCapturing) return;

    _isCapturing = true;
    try {
      // Flash first so the shutter feels immediate, and let it paint before
      // the capture blocks on the platform channel.
      _shutterFlash.value = true;
      await Future<void>.delayed(kShutterFlashDuration);
      _shutterFlash.value = false;

      final image = await session.snapshot();
      if (image is! MemoryImage) {
        throw StateError('snapshot returned ${image.runtimeType}, not bytes');
      }
      final bytes = image.bytes;

      // Written to app storage as well as the gallery: gal reports no path
      // back, and the capture dialog wants somewhere concrete to point at.
      final directory = await getApplicationDocumentsDirectory();
      final path = '${directory.path}/ar_capture_'
          '${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes, flush: true);

      await Gal.putImageBytes(bytes, album: 'Simply Curtains AR');

      if (!mounted) return;
      _screenshotPath = path;
      debugPrint('SCREENSHOT → saved to: $path');

      _thumbnail.value = bytes;
      _thumbnailTimer?.cancel();
      _thumbnailTimer = Timer(kThumbnailDuration, () {
        _thumbnail.value = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Screenshot saved ✓')),
      );
    } catch (e) {
      debugPrint('SCREENSHOT → failed: $e');
      _shutterFlash.value = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Text(
            e is GalException
                ? 'Could not save to gallery — permission denied'
                : 'Screenshot not supported on this device',
          ),
        ),
      );
    } finally {
      _isCapturing = false;
    }
  }

  void _reportSwatchUnsupported() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Color swap not supported on this device — noted as '
            'limitation'),
      ),
    );
  }

  /// Task 4: the gesture legend, once per session, auto-dismissed.
  void _showGestureInstructionsOnce() {
    if (_instructionsShown) return;
    _instructionsShown = true;
    _showInstructions.value = true;
    _instructionTimer?.cancel();
    _instructionTimer = Timer(kInstructionOverlayDuration, () {
      _showInstructions.value = false;
    });
  }

  /// Removing the *anchor* is the only reliable teardown. Android's `removeNode`
  /// calls `scene.removeChild(node)`, but an anchored node's parent is the
  /// AnchorNode rather than the scene, so it silently does nothing there;
  /// `removeAnchor` detaches the anchor and reparents its children on Android
  /// and drops the whole subtree on iOS.
  void _clearPlacement() {
    _scaleController.stop();
    _animationClock.stop();
    final anchor = _placedAnchor;
    if (anchor != null) {
      _arAnchorManager?.removeAnchor(anchor);
    }
    _placedAnchor = null;
    _placedNode = null;
    _placementPosition = null;
    _placementTransform = null;
    _nodeRotation = null;
    _hasPlacement.value = false;
  }

  /// Phase 4 Reset restores the default dimensions and returns the curtain to
  /// its anchor. It deliberately does *not* remove the placement — the anchor
  /// is what "original position" is measured from, and re-scanning a wall to
  /// get back to where you were would be worse than useless.
  void _resetPlacement() {
    _hintTimer?.cancel();
    _hint.value = null;
    _gestureAxis = null;
    _measurements.value = CurtainMeasurements.initial;
    _measurementsAtGestureStart = CurtainMeasurements.initial;
    if (_placedNode != null) _writeNodeTransform(1, force: true);
    debugPrint('RESIZE → reset to ${CurtainMeasurements.initial}');
  }

  /// Drives the 0 → full-size pop-in. Writing [ARNode.transform] pushes the
  /// matrix over the platform channel, so the node scales up in the AR scene.
  ///
  /// Throttled to [kTransformWriteInterval] because each write costs a channel
  /// round trip plus a recursive scene-graph search on Android. The final frame
  /// is always sent so the curtain never settles at the wrong size.
  ///
  /// The matrix is recomposed from scratch rather than using [ARNode.scale],
  /// whose setter reads rotation back via `transform.getRotation()` — that
  /// returns the basis with scale still baked in, so it corrupts the rotation
  /// as soon as scale differs from 1.
  void _applyScaleFrame() {
    final value = _scaleController.value;
    final isFinalFrame = value >= 1.0;
    final elapsed = _animationClock.elapsed;
    if (!isFinalFrame &&
        elapsed - _lastTransformWrite < kTransformWriteInterval) {
      return;
    }
    _lastTransformWrite = elapsed;
    _writeNodeTransform(Curves.easeOut.transform(value));
    if (isFinalFrame) _animationClock.stop();
  }

  void _writeNodeTransform(double progress, {bool force = false}) {
    final node = _placedNode;
    if (node == null) return;
    if (force) _lastTransformWrite = _animationClock.elapsed;
    node.transform = _nodeTransform(progress);
  }

  /// [progress] is the 0 → 1 pop-in. Width and height come from the live
  /// measurements as ratios against the model's nominal size, so the readout
  /// stays truthful whatever [kInitialModelScale] turns out to be.
  ///
  /// Depth is left at the base scale: stretching a curtain wider must not also
  /// make the fabric thicker.
  vm.Vector3 _nodeScale(double progress) {
    final measurements = _measurements.value;
    final base = kInitialModelScale * kModelScaleCompensation * progress;
    return vm.Vector3(
      math.max(
        base * measurements.widthM / kNominalModelWidthM,
        kMinPlacementScale,
      ),
      math.max(
        base * measurements.heightM / kNominalModelHeightM,
        kMinPlacementScale,
      ),
      math.max(base, kMinPlacementScale),
    );
  }

  vm.Matrix4 _nodeTransform(double progress) {
    final measurements = _measurements.value;
    final rotation = _nodeRotation ?? vm.Quaternion.identity();
    final scale = _nodeScale(progress);

    // Slide along the curtain's own horizontal axis. Its local +X is the
    // in-wall horizontal by construction (rectRotationForHit builds the basis
    // from gravity-projected up), so this tracks the wall however it is angled
    // rather than sliding through world X.
    final right = rotation.rotated(vm.Vector3(1, 0, 0));
    final translation = right * measurements.offsetXM;

    // Local to the anchor, and the anchor already sits on the hit point.
    return vm.Matrix4.compose(translation, rotation, scale);
  }

  // --------------------------------------------------------------- gestures

  /// A single [ScaleGestureRecognizer] drives all three gestures. Flutter
  /// forbids pairing a pan recognizer with a scale recognizer — scale is a
  /// superset — so one-finger drags arrive here too, as
  /// `pointerCount == 1` with a moving `focalPoint`.
  void _onScaleStart(ScaleStartDetails details) {
    // Unconditional, and deliberately above the placement guard: a drag or a
    // pinch is not a tap, so drop any placement the native side queued on
    // ACTION_DOWN before we knew which this was. A one-finger drag has already
    // passed kTapSlopPx by the time the recognizer accepts (Flutter's pan slop
    // is larger), but a two-finger pinch can be accepted on span alone with the
    // focal point barely moving — that is the case this catches.
    _pendingPlacementHit = null;
    _tapDisqualified = true;

    if (!_hasPlacement.value) return;
    _measurementsAtGestureStart = _measurements.value;
    _gestureAxis = null;
    _gestureStartFocal = details.localFocalPoint;
    _axisAnchorFocal = details.localFocalPoint;
    // Let the first update of a new gesture through the write throttle
    // immediately, so the curtain starts moving on the frame the finger does.
    _lastGestureWrite = Duration.zero;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (!_hasPlacement.value) return;

    // Two fingers always mean width, whatever the drag had locked to. The
    // finger count can change mid-gesture without the recognizer restarting,
    // so both directions of that transition have to be handled explicitly —
    // every update recomputes from [_measurementsAtGestureStart], and a stale
    // snapshot would revert whatever the gesture had already applied.
    if (details.pointerCount >= 2) {
      if (_gestureAxis != GestureAxis.width) {
        // A one-finger drag has just become a pinch. Re-baseline so the height
        // or position it already applied survives, and so the pinch scales
        // from the width as it now stands. The recognizer resets its reference
        // span when a pointer is added, so `details.scale` restarts at ~1.0
        // here and this stays consistent.
        _measurementsAtGestureStart = _measurements.value;
        _gestureAxis = GestureAxis.width;
      }
      _applyMeasurements(_measurementsAtGestureStart.withPinch(details.scale));
      return;
    }

    // A pinch that has lost a finger. Leaving the width where the user let go
    // is the only sane reading: there is no one-finger interpretation of a
    // width lock, and falling through would snap back to the pre-pinch width.
    if (_gestureAxis == GestureAxis.width) return;

    _gestureAxis ??= () {
      final axis = axisForDrag(details.localFocalPoint - _gestureStartFocal);
      // Anchor here rather than at the gesture's origin, so the dead zone is
      // not also applied as a jump the moment the axis commits.
      if (axis != null) _axisAnchorFocal = details.localFocalPoint;
      return axis;
    }();
    if (_gestureAxis == null) return; // still inside the dead zone

    final start = _measurementsAtGestureStart;
    final delta = details.localFocalPoint - _axisAnchorFocal;
    _applyMeasurements(switch (_gestureAxis!) {
      GestureAxis.height => start.withHeightDrag(delta.dy),
      GestureAxis.position => start.withPositionDrag(delta.dx),
      // Guarded above; holding the current value is the safe reading anyway.
      GestureAxis.width => _measurements.value,
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _gestureAxis = null;
    // Make sure the node ends on the exact final numbers rather than whatever
    // the throttle last let through.
    _writeNodeTransform(1, force: true);
  }

  void _applyMeasurements(CurtainMeasurements next) {
    final previous = _measurements.value;
    if (next == previous) return;
    // Never throttled: the readout is the thing the user is watching, and a
    // ValueNotifier assignment only repaints the two Text leaves in the card.
    _measurements.value = next;

    // Per dimension, and only on the transition *into* a limit. Tracking one
    // "at any limit" flag instead would swallow the buzz for a height that
    // pinned while the width happened to already be maxed out; firing on every
    // frame while pinned would buzz continuously.
    if (hitLimit(previous, next)) unawaited(HapticFeedback.heavyImpact());

    debugPrint('RESIZE → $next');

    // Throttled for the same reason the pop-in is: every write is a platform
    // channel round trip plus a recursive `scene.findByName` on Android, and a
    // drag produces one per vsync. [_onScaleEnd] always forces the final write,
    // so the curtain still settles on the exact numbers in the readout.
    final elapsed = _gestureClock.elapsed;
    if (elapsed - _lastGestureWrite < kTransformWriteInterval) return;
    _lastGestureWrite = elapsed;
    _writeNodeTransform(1);
  }

  // ---------------------------------------------------------- pose telemetry

  void _startPosePolling() {
    _poseTimer?.cancel();
    _poseTimer =
        Timer.periodic(kPosePollInterval, (_) => unawaited(_pollPose()));
  }

  Future<void> _pollPose() async {
    final session = _arSessionManager;
    if (session == null || !_isResumed) return;

    final cameraPose = await session.getCameraPose();
    if (!mounted) return;

    if (cameraPose == null) {
      _registerTrackingStrike();
      return;
    }

    final camera = cameraPose.getTranslation();
    final previous = _lastCameraPosition;

    // A pose that does not budge at all while the IMU says the phone is moving
    // means the tracker has stopped updating. The plugin surfaces no ARCore
    // TrackingState / ARCamera.trackingState, so this heuristic is what we have.
    final frozen = previous != null &&
        (camera - previous).length < kFrozenPoseEpsilonM &&
        _motion.value != MotionState.still;
    if (frozen) {
      _registerTrackingStrike();
    } else {
      _clearTrackingStrikes();
    }
    _lastCameraPosition = camera;

    if (_placedAnchor == null) {
      _lastLoggedCameraPosition = camera;
      return;
    }

    final origin = _lastLoggedCameraPosition;
    if (origin == null) {
      _lastLoggedCameraPosition = camera;
      return;
    }
    if ((camera - origin).length < kCameraMoveLogThresholdM) return;

    final travelled = (camera - origin).length;
    _lastLoggedCameraPosition = camera;
    final anchored = await _isRectangleStillAnchored();
    if (anchored) {
      debugPrint(
        'GLB STABLE → camera moved ${travelled.toStringAsFixed(2)}m, '
        'model still anchored',
      );
    } else {
      debugPrint(
        'GLB DRIFTED → camera moved ${travelled.toStringAsFixed(2)}m, '
        'model no longer at its placement pose',
      );
    }
  }

  /// NOTE: only meaningful on Android. `getAnchorPose` returns the live
  /// `Anchor.pose` there, which ARCore keeps updating, so real drift shows up.
  /// iOS returns the stored `ARAnchor.transform`, which is immutable once the
  /// anchor is created — so this reads `true` on iOS as long as the anchor is
  /// still registered, and reports nothing about actual drift.
  Future<bool> _isRectangleStillAnchored() async {
    final session = _arSessionManager;
    final anchor = _placedAnchor;
    final placedAt = _placementPosition;
    if (session == null || anchor == null || placedAt == null) return false;

    final pose = await session.getPose(anchor);
    if (pose == null) return false;
    final drift = (pose.getTranslation() - placedAt).length;
    if (drift > kAnchorDriftToleranceM) {
      debugPrint('ANCHOR DRIFT → ${drift.toStringAsFixed(3)} m from placement');
      return false;
    }
    return true;
  }

  /// Tracking can only be *lost* after it has been had. `getCameraPose` fails
  /// for the first frames of every session, before ARCore/ARKit produce one —
  /// without this gate a cold start always flashes the recovery overlay.
  void _registerTrackingStrike() {
    if (!_trackingEstablished) return;
    _trackingStrikes++;
    if (_trackingStrikes >= kTrackingStrikesForLoss && !_trackingLost.value) {
      debugPrint('TRACKING LOST → camera pose stopped updating');
      _trackingLost.value = true;
    }
  }

  void _clearTrackingStrikes() {
    _trackingEstablished = true;
    _trackingStrikes = 0;
    if (_trackingLost.value) {
      debugPrint('TRACKING RECOVERED → camera pose updating again');
      _trackingLost.value = false;
    }
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    if (_permission == _PermissionState.checking) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_permission == _PermissionState.denied) {
      return _buildPermissionDenied(context);
    }
    if (_arError != null) {
      return _buildArUnsupported(context);
    }
    return _buildArExperience(context);
  }

  Widget _buildPermissionDenied(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.camera_alt,
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'Camera permission is required for AR preview',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 32),
                const ElevatedButton(
                  onPressed: openAppSettings,
                  child: Text('Open Settings'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArUnsupported(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.view_in_ar_outlined,
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'AR is not supported on this device',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Use Manual Mode'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Every child here is either the cached [_arSurface] or a
  /// [ValueListenableBuilder] over one notifier, so this method runs once and
  /// then only the leaf that actually changed rebuilds.
  Widget _buildArExperience(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _arSurface,
          // Swapped out entirely once a wall is found, which disposes the
          // pulsing ring's ticker instead of leaving it running at 0 opacity.
          _ScanOverlayHost(
            planeCount: _planeCount,
            hasPlacement: _hasPlacement,
            scanSeconds: _scanSeconds,
            motion: _motion,
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _trackingLost,
            builder: (context, lost, _) =>
                lost ? const _TrackingLostOverlay() : const SizedBox.shrink(),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(context),
                ValueListenableBuilder<bool>(
                  valueListenable: _hasPlacement,
                  builder: (context, placed, _) => placed
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: _MeasurementCard(measurements: _measurements),
                        )
                      : const SizedBox.shrink(),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _showSurfaceFoundToast,
                  builder: (context, show, _) => show
                      ? const _SurfaceFoundToast()
                      : const SizedBox.shrink(),
                ),
                const Spacer(),
                _buildBottomPrompt(),
                _buildSwatchRow(),
                _buildBottomBar(context),
                _buildModelLoadingStrip(),
              ],
            ),
          ),
          // Task 2b: a tap that beat the preload waits behind this rather than
          // being dropped.
          ValueListenableBuilder<bool>(
            valueListenable: _awaitingModel,
            builder: (context, waiting, _) =>
                waiting ? const _ModelWaitOverlay() : const SizedBox.shrink(),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _showInstructions,
            builder: (context, show, _) =>
                show ? const _GestureInstructions() : const SizedBox.shrink(),
          ),
          // Task 3D: shutter flash. Above every other overlay so the whole
          // frame goes white, and non-interactive so it cannot eat a tap.
          ValueListenableBuilder<bool>(
            valueListenable: _shutterFlash,
            builder: (context, flashing, _) => IgnorePointer(
              child: AnimatedOpacity(
                opacity: flashing ? 1 : 0,
                duration: flashing ? Duration.zero : kShutterFadeDuration,
                child: const ColoredBox(
                  color: Colors.white,
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: ValueListenableBuilder<bool>(
                valueListenable: _boxPlaced,
                builder: (context, placed, _) => placed
                    ? Padding(
                        padding: const EdgeInsets.only(top: 56, right: 12),
                        child: FloatingActionButton(
                          heroTag: 'ar_capture',
                          onPressed: _captureScreenshot,
                          tooltip: 'Capture photo',
                          child: const Icon(Icons.camera_alt_rounded),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ValueListenableBuilder<Uint8List?>(
                valueListenable: _thumbnail,
                builder: (context, bytes, _) =>
                    _CaptureThumbnail(bytes: bytes),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Task 1: subtle strip pinned to the very bottom while the curtain stages
  /// and its renderable compiles.
  ///
  /// Text only, deliberately. An indeterminate [CircularProgressIndicator]
  /// never stops animating, so putting one here would repaint over the camera
  /// feed every vsync for the whole load — precisely the always-on ticker the
  /// scanning overlay was fixed to avoid. The modal wait in
  /// [_ModelWaitOverlay] can afford a spinner because it is transient.
  Widget _buildModelLoadingStrip() {
    return ValueListenableBuilder<ModelLoadState>(
      valueListenable: _modelState,
      builder: (context, state, _) {
        if (state != ModelLoadState.loading) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: Colors.black45,
          padding: const EdgeInsets.symmetric(vertical: 6),
          alignment: Alignment.center,
          child: const Text(
            'Loading curtain...',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        );
      },
    );
  }

  /// Tasks 3C and 3F: the palette, with the reset beside it.
  ///
  /// Mounted from the moment the screen builds rather than swapped in when a
  /// panel lands — [SwatchSelector] animates on its `visible` flag, and a
  /// widget that is inserted and animated in the same frame starts its slide
  /// from wherever the layout first put it.
  Widget _buildSwatchRow() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwatchSelector(
          swatches: kSwatches,
          selectedSwatch: _selectedSwatch,
          onSwatchSelected: (swatch) => unawaited(_applySwatch(swatch)),
          visible: _swatchSelectorVisible,
        ),
        if (_swatchSelectorVisible)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: TextButton.icon(
                onPressed: _selectedSwatch == kSwatches.first
                    ? null
                    : () => unawaited(_applySwatch(kSwatches.first)),
                icon: const Icon(Icons.format_color_reset, size: 16),
                label: const Text('Reset Color'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white38,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// The hint and the standing prompt share a slot, so only one shows at a time.
  Widget _buildBottomPrompt() {
    return ValueListenableBuilder<_Hint?>(
      valueListenable: _hint,
      builder: (context, hint, _) {
        if (hint != null) return _HintCard(hint: hint);
        return ValueListenableBuilder<bool>(
          valueListenable: _hasPlacement,
          builder: (context, placed, _) {
            if (placed) return const SizedBox.shrink();
            return ValueListenableBuilder<int>(
              valueListenable: _planeCount,
              builder: (context, planes, _) =>
                  planes > 0 ? const _TapPrompt() : const SizedBox.shrink(),
            );
          },
        );
      },
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: Colors.black38,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Back',
          ),
          const Text(
            'AR Preview',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          _StatusChip(planeCount: _planeCount, hasPlacement: _hasPlacement),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      color: Colors.black38,
      child: ValueListenableBuilder<bool>(
        valueListenable: _hasPlacement,
        builder: (context, placed, _) => Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: placed ? _resetPlacement : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Reset'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white38,
                  side: BorderSide(
                    color: placed ? Colors.white70 : Colors.white24,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: placed ? () => _captureMeasurements(context) : null,
                child: const Text('Next →'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Stands in for handing the measurements to the quote flow that follows
  /// this MVP.
  void _captureMeasurements(BuildContext context) {
    final measurements = _measurements.value;
    debugPrint('CAPTURED → $measurements');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AR Measurement Captured'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CaptureRow(label: 'Fabric/Color', value: _selectedSwatch.name),
            const SizedBox(height: 4),
            _MeasurementRow(label: 'Width', valueCm: measurements.widthCm),
            const SizedBox(height: 4),
            _MeasurementRow(label: 'Height', valueCm: measurements.heightCm),
            const SizedBox(height: 4),
            _CaptureRow(
              label: 'Photo',
              value: _screenshotPath == null ? 'Not taken' : 'Saved ✓',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

/// A `Label:  value` line in the capture dialog, laid out on the same 72px
/// label column as [_MeasurementRow] so the two read as one table.
class _CaptureRow extends StatelessWidget {
  const _CaptureRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 108,
          child: Text('$label:', style: const TextStyle(fontSize: 16)),
        ),
        Flexible(
          child: Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// Task 3D: proof the capture landed, bottom-left, gone after a few seconds.
///
/// Fades itself out rather than vanishing, and holds its slot with a
/// zero-opacity box until the fade finishes — swapping straight to a
/// `SizedBox.shrink` would cut the animation off on its first frame.
class _CaptureThumbnail extends StatelessWidget {
  const _CaptureThumbnail({required this.bytes});

  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final data = bytes;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: data == null ? 0 : 1,
        duration: kThumbnailFadeDuration,
        curve: Curves.easeOut,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 16),
          child: SizedBox(
            width: kThumbnailSize,
            height: kThumbnailSize,
            child: data == null
                ? null
                : ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white70, width: 2),
                      ),
                      child: Image.memory(
                        data,
                        width: kThumbnailSize,
                        height: kThumbnailSize,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ModelWaitOverlay extends StatelessWidget {
  const _ModelWaitOverlay();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: ColoredBox(
        color: Colors.black45,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text(
                'Loading curtain...',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =========================================================== scanning overlay

/// Owns the fade-out and, crucially, the *removal* of the scanning overlay.
/// Leaving it mounted at zero opacity kept a repeating ticker alive for the
/// whole session, costing a rebuild every frame forever.
class _ScanOverlayHost extends StatelessWidget {
  const _ScanOverlayHost({
    required this.planeCount,
    required this.hasPlacement,
    required this.scanSeconds,
    required this.motion,
  });

  final ValueListenable<int> planeCount;
  final ValueListenable<bool> hasPlacement;
  final ValueListenable<int> scanSeconds;
  final ValueListenable<MotionState> motion;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: planeCount,
      builder: (context, planes, _) => ValueListenableBuilder<bool>(
        valueListenable: hasPlacement,
        builder: (context, placed, _) {
          final scanning = planes == 0 && !placed;
          return AnimatedSwitcher(
            duration: kScanFadeDuration,
            child: scanning
                ? _ScanningOverlay(scanSeconds: scanSeconds, motion: motion)
                : const SizedBox.shrink(),
          );
        },
      ),
    );
  }
}

class _ScanningOverlay extends StatelessWidget {
  const _ScanningOverlay({required this.scanSeconds, required this.motion});

  final ValueListenable<int> scanSeconds;
  final ValueListenable<MotionState> motion;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ScanDial(scanSeconds: scanSeconds),
            const SizedBox(height: 28),
            ValueListenableBuilder<int>(
              valueListenable: scanSeconds,
              builder: (context, seconds, _) =>
                  ValueListenableBuilder<MotionState>(
                valueListenable: motion,
                builder: (context, motionState, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        scanHeadline(seconds),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(blurRadius: 8, color: Colors.black87)
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        scanHint(seconds, motionState),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          shadows: [
                            Shadow(blurRadius: 8, color: Colors.black87)
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            _MotionIndicator(motion: motion),
          ],
        ),
      ),
    );
  }
}

_ScanStage _scanStageFor(int seconds) {
  if (seconds < 5) return _ScanStage.starting;
  if (seconds < 15) return _ScanStage.scanning;
  if (seconds < 30) return _ScanStage.slow;
  return _ScanStage.struggling;
}

@visibleForTesting
String scanHeadline(int seconds) {
  switch (_scanStageFor(seconds)) {
    case _ScanStage.starting:
      return 'Point your phone at the wall around your window';
    case _ScanStage.scanning:
      return 'Sweep slowly across the wall';
    case _ScanStage.slow:
      return 'Still looking — try moving closer (0.5–1.5 m)';
    case _ScanStage.struggling:
      return 'Struggling to find a wall';
  }
}

/// Concrete next action, escalating as time passes. The wall-specific advice
/// matters: ARCore fits vertical planes from texture, so a bare painted wall can
/// genuinely never resolve while the frame beside it resolves in seconds.
@visibleForTesting
String scanHint(int seconds, MotionState motion) {
  switch (motion) {
    case MotionState.still:
      return 'Phone is stationary — move it to build depth';
    case MotionState.tooFast:
      return 'Slow down — moving too fast to track';
    case MotionState.good:
      break;
  }
  switch (_scanStageFor(seconds)) {
    case _ScanStage.starting:
    case _ScanStage.scanning:
      return 'Typically takes ${kTypicalScanDuration.inSeconds}s or less';
    case _ScanStage.slow:
      return 'Aim at the window frame or trim, not blank paint';
    case _ScanStage.struggling:
      return 'Blank walls cannot be tracked — target a frame, '
          'curtain rail or picture edge';
  }
}

/// Pulsing ring with the live elapsed-time readout in the middle.
///
/// The ring drives its own controller and repaints behind a [RepaintBoundary],
/// so the pulse never rebuilds anything above it — and the seconds counter is
/// scoped to its own builder, so a tick repaints one [Text].
class _ScanDial extends StatefulWidget {
  const _ScanDial({required this.scanSeconds});

  final ValueListenable<int> scanSeconds;

  @override
  State<_ScanDial> createState() => _ScanDialState();
}

class _ScanDialState extends State<_ScanDial>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  late final Animation<double> _pulse = Tween<double>(
    begin: 0.85,
    end: 1.15,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      height: 150,
      child: Stack(
        alignment: Alignment.center,
        children: [
          RepaintBoundary(
            child: ScaleTransition(
              scale: _pulse,
              // const: ScaleTransition animates the transform only, so this
              // subtree is built once and never again.
              child: const SizedBox(
                width: 140,
                height: 140,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(
                      BorderSide(color: Colors.white70, width: 3),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<int>(
                valueListenable: widget.scanSeconds,
                builder: (context, seconds, _) => Text(
                  '${seconds}s',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                  ),
                ),
              ),
              const Text(
                'scanning',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  letterSpacing: 1.2,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Live proof the sensors are feeding data: the label changes as you move.
class _MotionIndicator extends StatelessWidget {
  const _MotionIndicator({required this.motion});

  final ValueListenable<MotionState> motion;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MotionState>(
      valueListenable: motion,
      builder: (context, state, _) {
        final (String label, Color color, IconData icon) = switch (state) {
          MotionState.still => (
              'Not moving',
              Colors.orange,
              Icons.pause_circle
            ),
          MotionState.good => (
              'Scanning motion',
              Colors.lightGreenAccent,
              Icons.gps_not_fixed
            ),
          MotionState.tooFast => (
              'Too fast',
              Colors.redAccent,
              Icons.vibration
            ),
        };
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 15),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: color, fontSize: 12)),
            ],
          ),
        );
      },
    );
  }
}

// ==================================================================== chrome

class _TrackingLostOverlay extends StatelessWidget {
  const _TrackingLostOverlay();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.motion_photos_off, color: Colors.amber, size: 56),
              SizedBox(height: 16),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Tracking lost — move phone slowly to recover',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.planeCount, required this.hasPlacement});

  final ValueListenable<int> planeCount;
  final ValueListenable<bool> hasPlacement;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: planeCount,
      builder: (context, planes, _) => ValueListenableBuilder<bool>(
        valueListenable: hasPlacement,
        builder: (context, placed, _) {
          final ready = planes > 0;
          final label = placed
              ? 'Placed'
              : ready
                  ? 'Ready • $planes ${planes == 1 ? 'wall' : 'walls'}'
                  : 'Scanning...';
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: ready ? Colors.green : Colors.orange,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One-shot entrance animation.
///
/// Deliberately not flutter_animate: its `Animate` widget posts a
/// zero-duration `Timer` from `initState` and again from every
/// `didUpdateWidget` restart, so a card living inside a rebuilding builder
/// queues timers it does not need. [FadeTransition] and [SlideTransition]
/// only repaint — the child subtree is built once — and the controller stops
/// itself when it completes.
class _FadeSlideIn extends StatefulWidget {
  const _FadeSlideIn({required this.child, required this.beginOffset});

  final Widget child;
  final Offset beginOffset;

  @override
  State<_FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<_FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  )..forward();

  late final Animation<double> _fade =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);

  late final Animation<Offset> _slide =
      Tween<Offset>(begin: widget.beginOffset, end: Offset.zero).animate(_fade);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

class _SurfaceFoundToast extends StatelessWidget {
  const _SurfaceFoundToast();

  @override
  Widget build(BuildContext context) {
    return _FadeSlideIn(
      beginOffset: const Offset(0, -0.4),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.green.shade600,
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text(
                'Wall found!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================== live measurements

/// Task 2: the live width/height readout, pinned top-left over the AR view.
///
/// A plain UI overlay, not an AR-space label — the numbers have to stay legible
/// and stationary while the curtain behind them is being dragged around.
class _MeasurementCard extends StatelessWidget {
  const _MeasurementCard({required this.measurements});

  final ValueListenable<CurtainMeasurements> measurements;

  @override
  Widget build(BuildContext context) {
    return _FadeSlideIn(
      beginOffset: const Offset(-0.3, 0),
      child: Container(
        margin: const EdgeInsets.only(left: 12, top: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: kMeasurementCardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        // Scoped as tightly as possible: a drag reassigns this notifier every
        // frame, and this is the only subtree that should rebuild for it.
        child: ValueListenableBuilder<CurtainMeasurements>(
          valueListenable: measurements,
          builder: (context, live, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MeasurementRow(
                label: 'Width',
                valueCm: live.widthCm,
                color: Colors.white,
                animated: true,
              ),
              const SizedBox(height: 4),
              _MeasurementRow(
                label: 'Height',
                valueCm: live.heightCm,
                color: Colors.white,
                animated: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One `Label:  NNN cm` line, shared by the live card and the capture dialog.
class _MeasurementRow extends StatelessWidget {
  const _MeasurementRow({
    required this.label,
    required this.valueCm,
    this.color,
    this.animated = false,
  });

  final String label;
  final double valueCm;

  /// Null takes the ambient text colour, which is what the dialog wants.
  final Color? color;

  /// Tweens to the new number instead of snapping to it. See [_AnimatedCm].
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final valueStyle = TextStyle(
      color: color,
      fontSize: 16,
      fontWeight: FontWeight.w700,
      // Every digit gets the same advance width, so the row does not twitch as
      // the value crosses 99 → 100 mid-drag.
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            '$label:',
            style: TextStyle(
              color: color?.withValues(alpha: 0.7),
              fontSize: 16,
            ),
          ),
        ),
        animated
            ? _AnimatedCm(valueCm: valueCm, style: valueStyle)
            : Text('${valueCm.round()} cm', style: valueStyle),
      ],
    );
  }
}

/// A centimetre readout that counts to its new value over
/// [kMeasurementTweenDuration] rather than jumping.
///
/// [TweenAnimationBuilder] rather than flutter_animate, which drives the rest
/// of this phase's chrome. `Animate` posts a zero-duration `Timer` from
/// `initState` and from every `didUpdateWidget` restart — fine for the one-shot
/// instruction overlay, but this widget's value changes on *every frame* of a
/// drag, so that would queue a timer per vsync for as long as the finger is
/// down. `TweenAnimationBuilder` retargets from wherever the previous tween had
/// got to, which is exactly the trailing-counter feel wanted here, and costs
/// one controller no matter how fast the value moves.
class _AnimatedCm extends StatelessWidget {
  const _AnimatedCm({required this.valueCm, required this.style});

  final double valueCm;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // No `begin`: the first build lands on the value without animating, and
      // later builds interpolate from the current one.
      tween: Tween<double>(end: valueCm),
      duration: kMeasurementTweenDuration,
      curve: Curves.easeOut,
      builder: (context, value, _) => Text('${value.round()} cm', style: style),
    );
  }
}

/// Task 4: the gesture legend, shown once for [kInstructionOverlayDuration]
/// after the first placement.
///
/// The fade-out has to be driven from inside the widget. The host swaps this
/// for a `SizedBox` the instant the timer fires, so an outside-in animation
/// would be unmounted before it could play — instead the whole in-hold-out
/// timeline runs here and finishes exactly as the host removes it.
///
/// [IgnorePointer] matters as much as the animation: the legend sits over the
/// AR view for three seconds, and a user who starts dragging immediately must
/// not have the gesture eaten by a label telling them to drag.
class _GestureInstructions extends StatelessWidget {
  const _GestureInstructions();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          decoration: BoxDecoration(
            color: kMeasurementCardColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InstructionLine(glyph: '↕', text: 'Drag up/down to adjust height'),
              SizedBox(height: 10),
              _InstructionLine(glyph: '↔', text: 'Drag left/right to reposition'),
              SizedBox(height: 10),
              _InstructionLine(glyph: '✦', text: 'Pinch to adjust width'),
            ],
          ),
        ),
      ),
    )
        .animate()
        .fadeIn(duration: kInstructionFadeIn, curve: Curves.easeOut)
        .slideY(begin: 0.12, end: 0, curve: Curves.easeOut)
        .then(delay: kInstructionHold)
        .fadeOut(duration: kInstructionFadeOut, curve: Curves.easeIn);
  }
}

class _InstructionLine extends StatelessWidget {
  const _InstructionLine({required this.glyph, required this.text});

  final String glyph;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 28,
          child: Text(
            glyph,
            style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontSize: 20,
              height: 1.1,
            ),
          ),
        ),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ],
    );
  }
}

class _TapPrompt extends StatelessWidget {
  const _TapPrompt();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.touch_app, color: Colors.white, size: 18),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Tap a highlighted wall to place curtain',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard({required this.hint});

  final _Hint hint;

  @override
  Widget build(BuildContext context) {
    final detail = hint.detail;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange, width: 1.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.touch_app, color: Colors.orange),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hint.message,
                  style: const TextStyle(
                    color: Colors.orange,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
