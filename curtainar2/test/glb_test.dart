// Guards the GLB container check.
//
// This exists because both platforms fail opaquely on a bad model: Sceneform
// says "Unable to load renderable" and GLTFSceneKit throws a generic parse
// error. Neither tells you the file is a text placeholder — which is exactly
// what assets/models/curtain.glb currently is.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/material.dart';

import 'package:simply_curtains_ar/models/swatch.dart';
import 'package:simply_curtains_ar/screens/ar_screen.dart';

Uint8List _readAsset(String path) => File(path).readAsBytesSync();

/// Builds a well-formed GLB header + JSON chunk, so tests can perturb one field
/// at a time.
Uint8List _glb({
  int magic = 0x46546C67,
  int version = 2,
  int? declaredLength,
  int jsonChunkType = 0x4E4F534A,
  int? jsonChunkLength,
  String json = '{"asset":{"version":"2.0"}}',
}) {
  final payload = <int>[...utf8.encode(json)];
  while (payload.length % 4 != 0) {
    payload.add(0x20);
  }
  final total = 12 + 8 + payload.length;
  final bytes = BytesBuilder();
  final header = ByteData(20);
  header.setUint32(0, magic, Endian.little);
  header.setUint32(4, version, Endian.little);
  header.setUint32(8, declaredLength ?? total, Endian.little);
  header.setUint32(12, jsonChunkLength ?? payload.length, Endian.little);
  header.setUint32(16, jsonChunkType, Endian.little);
  bytes.add(header.buffer.asUint8List());
  bytes.add(payload);
  return bytes.toBytes();
}

void main() {
  group('glbContainerError', () {
    test('accepts a well-formed GLB', () {
      expect(glbContainerError(_glb()), isNull);
    });

    test('accepts the generated placement rectangle', () {
      expect(
        glbContainerError(_readAsset('assets/models/placement_rect.glb')),
        isNull,
      );
    });

    test('rejects the text placeholder currently shipped as curtain.glb', () {
      // The file reads "glTF Placeholder - replace with your Meshy AI
      // curtain.glb file". It starts with the ASCII bytes "glTF", so a naive
      // magic-number check passes it straight through to the native loader.
      final bytes = _readAsset('assets/models/curtain.glb');
      final error = glbContainerError(bytes);

      expect(error, isNotNull,
          reason: 'a 62-byte text file must not reach the native loader');
      expect(error, contains('version'));
    });

    test('rejects a file too short to hold a header', () {
      expect(
        glbContainerError(Uint8List.fromList(utf8.encode('glTF'))),
        contains('too short'),
      );
    });

    test('names Git LFS pointers as a likely cause of a short file', () {
      final pointer = utf8.encode(
        'version https://git-lfs.github.com/spec/v1\n',
      );
      expect(
        glbContainerError(Uint8List.fromList(pointer.sublist(0, 12))),
        contains('LFS'),
      );
    });

    test('rejects a wrong magic number', () {
      expect(glbContainerError(_glb(magic: 0x12345678)), contains('not a GLB'));
    });

    test('rejects glTF 1.0', () {
      expect(glbContainerError(_glb(version: 1)), contains('version 1'));
    });

    test('rejects a truncated file whose header over-declares', () {
      expect(
        glbContainerError(_glb(declaredLength: 9999)),
        contains('truncated or corrupt'),
      );
    });

    test('rejects a first chunk that is not JSON', () {
      expect(
        glbContainerError(_glb(jsonChunkType: 0x004E4942)), // BIN
        contains('not JSON'),
      );
    });

    test('rejects a JSON chunk that runs past the end of the file', () {
      expect(
        glbContainerError(_glb(jsonChunkLength: 9999, declaredLength: null)),
        anyOf(contains('past the end'), contains('truncated')),
      );
    });
  });

  group('glbSummary', () {
    test('reads the placement rectangle we generated', () {
      final summary = glbSummary(
        _readAsset('assets/models/placement_rect.glb'),
      )!;

      expect(summary.meshCount, 1);
      expect(summary.materialCount, 1);
      expect(summary.vertexCount, 4);
      expect(summary.width, closeTo(1.0, 1e-6));
      expect(summary.height, closeTo(2.0, 1e-6));
      expect(summary.depth, closeTo(0.0, 1e-6));
    });

    test('a 2 m tall model needs no rescaling', () {
      final summary = glbSummary(
        _readAsset('assets/models/placement_rect.glb'),
      )!;
      expect(summary.suggestedScaleForHeight(2.0), closeTo(1.0, 1e-6));
      expect(summary.suggestedScaleForHeight(1.0), closeTo(0.5, 1e-6));
    });

    test('the real rectangle is not flagged as a placeholder', () {
      final summary = glbSummary(
        _readAsset('assets/models/placement_rect.glb'),
      )!;
      expect(summary.looksLikePlaceholder, isFalse);
    });

    test('curtain1.glb is a single untextured triangle, not a curtain', () {
      // 3 vertices spanning (0,0,0)-(1,1,0), POSITION only, zero materials,
      // generator "placeholder". Recorded here so that if a real Meshy export
      // replaces it, this test fails and tells you to update the docs.
      final summary = glbSummary(_readAsset('assets/models/curtain1.glb'))!;

      expect(summary.meshCount, 1);
      expect(summary.materialCount, 0);
      expect(summary.vertexCount, 3);
      expect(summary.looksLikePlaceholder, isTrue,
          reason: 'no materials and 3 vertices cannot render as fabric');
    });

    test('suggests the scale that would make a model the requested height', () {
      const summary = GlbSummary(
        meshCount: 1,
        materialCount: 2,
        vertexCount: 2048,
        min: [-100.0, 0.0, -5.0],
        max: [100.0, 200.0, 5.0],
      );

      // A 200-unit-tall Meshy export needs 0.01 to become a 2 m curtain — the
      // exact case the calibration buttons exist to find by hand.
      expect(summary.suggestedScaleForHeight(2.0), closeTo(0.01, 1e-9));
      expect(summary.looksLikePlaceholder, isFalse);
    });

    test('copes with a model whose accessors carry no bounds', () {
      const summary = GlbSummary(
        meshCount: 1,
        materialCount: 1,
        vertexCount: 64,
        min: null,
        max: null,
      );
      expect(summary.height, isNull);
      expect(summary.suggestedScaleForHeight(2.0), isNull);
      expect(summary.toString(), contains('bounds unknown'));
    });

    test('returns null rather than throwing on unreadable JSON', () {
      expect(glbSummary(_glb(json: 'not json at all')), isNull);
    });
  });

  // The Phase 5 panel has no asset file behind it — the GLB is authored at
  // runtime so a colour can be baked into its material. That makes these
  // checks the only thing standing between a malformed container and an
  // opaque "Unable to load renderable" on the device.
  group('runtime box', () {
    Uint8List box({
      double width = 1.0,
      double height = 2.0,
      double depth = 0.05,
      Color color = const Color(0xFFF5F5F5),
    }) =>
        buildBoxGlb(
          width: width,
          height: height,
          depth: depth,
          color: color,
        );

    test('produces a container the loader will accept', () {
      expect(glbContainerError(box()), isNull);
    });

    test('declares a length that matches the bytes it emitted', () {
      final bytes = box();
      final declared = ByteData.view(bytes.buffer).getUint32(8, Endian.little);

      expect(declared, bytes.lengthInBytes);
      expect(bytes.lengthInBytes % 4, 0, reason: 'chunks stay 4-byte aligned');
    });

    test('carries real geometry and a material, not a placeholder', () {
      final summary = glbSummary(box())!;

      expect(summary.meshCount, 1);
      expect(summary.materialCount, 1);
      // Four corners per face so each face gets its own normal.
      expect(summary.vertexCount, 24);
      expect(summary.looksLikePlaceholder, isFalse);
    });

    test('reports bounds matching the requested size', () {
      final summary = glbSummary(box(width: 0.8, height: 1.8, depth: 0.05))!;

      expect(summary.width, closeTo(0.8, 1e-6));
      expect(summary.height, closeTo(1.8, 1e-6));
      expect(summary.depth, closeTo(0.05, 1e-6));
    });

    test('a panel authored at nominal size needs no scale correction', () {
      // The gesture readout multiplies by measurement/nominal, so authoring the
      // panel at exactly the nominal size is what keeps the centimetre figures
      // truthful at scale 1.
      final summary = glbSummary(
        box(width: kNominalModelWidthM, height: kNominalModelHeightM),
      )!;

      expect(
        summary.suggestedScaleForHeight(kNominalModelHeightM),
        closeTo(1.0, 1e-6),
      );
    });

    test('bakes the swatch colour into the material, in linear space', () {
      final decoded = _decodeJsonChunk(box(color: const Color(0xFF795548)));
      final factor = (decoded['materials'] as List).first['pbrMetallicRoughness']
          ['baseColorFactor'] as List;

      // 0x79 -> 0.4745 sRGB -> 0.1912 linear. Emitting the sRGB value straight
      // through is why hand-written glTF colours come out washed out; the gap
      // here is more than 2x on the darkest channel.
      expect((factor[0] as num).toDouble(), closeTo(0.191202, 1e-5));
      expect((factor[1] as num).toDouble(), closeTo(0.090842, 1e-5));
      expect((factor[2] as num).toDouble(), closeTo(0.064803, 1e-5));
      expect((factor[3] as num).toDouble(), closeTo(1.0, 1e-6));
    });

    test('every swatch in the palette produces a loadable panel', () {
      for (final swatch in kSwatches) {
        final bytes = box(color: swatch.color);
        expect(glbContainerError(bytes), isNull, reason: swatch.name);
        expect(glbSummary(bytes)!.looksLikePlaceholder, isFalse,
            reason: swatch.name);
      }
    });
  });
}

/// Reads the JSON chunk back out of a GLB.
Map<String, dynamic> _decodeJsonChunk(Uint8List bytes) {
  final data = ByteData.view(bytes.buffer);
  final length = data.getUint32(12, Endian.little);
  return jsonDecode(utf8.decode(bytes.sublist(20, 20 + length)).trim())
      as Map<String, dynamic>;
}
