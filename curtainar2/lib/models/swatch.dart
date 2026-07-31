import 'package:flutter/material.dart';

/// A fabric option the user can apply to the placed panel.
///
/// Colour only — Phase 5 is a mechanics test, so there is no texture, weave or
/// price behind these yet. [id] is the identity: two swatches with the same id
/// are the same swatch whatever else changes, which keeps selection comparisons
/// stable if the palette is ever reordered or renamed.
@immutable
class Swatch {
  const Swatch({required this.id, required this.name, required this.color});

  final String id;
  final String name;
  final Color color;

  /// `#RRGGBB`, for the console logs Phase 5 is evaluated against.
  String get hex =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  bool operator ==(Object other) => other is Swatch && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => '$name ($hex)';
}

/// The Phase 5 palette. The first entry is the colour the panel is placed in,
/// and the one "Reset Color" returns to.
const List<Swatch> kSwatches = <Swatch>[
  Swatch(id: 'white', name: 'White Linen', color: Color(0xFFF5F5F5)),
  Swatch(id: 'beige', name: 'Beige Cotton', color: Color(0xFFF5DEB3)),
  Swatch(id: 'grey', name: 'Slate Grey', color: Color(0xFF9E9E9E)),
  Swatch(id: 'brown', name: 'Mocha Brown', color: Color(0xFF795548)),
];
