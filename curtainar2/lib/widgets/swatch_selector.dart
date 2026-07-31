import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/swatch.dart';

const double kSwatchChipWidth = 64;
const double kSwatchChipHeight = 80;
const double kSwatchColorHeight = 52;

const Color kSwatchSelectedBorder = Color(0xFFD4A843);
const double kSwatchBorderWidth = 2.5;

const Duration kSwatchSlideDuration = Duration(milliseconds: 300);

/// Horizontal palette of fabric chips, shown once a panel is on the wall.
///
/// The row slides in from below rather than simply appearing: it arrives right
/// after placement, and a strip that materialises under the user's thumb
/// mid-gesture is easy to hit by accident.
class SwatchSelector extends StatelessWidget {
  const SwatchSelector({
    super.key,
    required this.swatches,
    required this.selectedSwatch,
    required this.onSwatchSelected,
    this.visible = true,
  });

  final List<Swatch> swatches;
  final Swatch selectedSwatch;
  final void Function(Swatch) onSwatchSelected;

  /// Drives the slide. False parks the row off the bottom edge.
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // Nothing to tap while it is parked off-screen — and a tap there would
      // otherwise fall through to the AR view and be read as a placement tap.
      ignoring: !visible,
      child: SizedBox(
        height: kSwatchChipHeight,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: swatches.length,
          separatorBuilder: (context, index) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final swatch = swatches[index];
            return _SwatchChip(
              swatch: swatch,
              selected: swatch == selectedSwatch,
              onTap: () => onSwatchSelected(swatch),
            );
          },
        ),
      ),
    )
        .animate(target: visible ? 1 : 0)
        .slideY(
          begin: 1,
          end: 0,
          duration: kSwatchSlideDuration,
          curve: Curves.easeOut,
        )
        .fadeIn(duration: kSwatchSlideDuration, curve: Curves.easeOut);
  }
}

class _SwatchChip extends StatelessWidget {
  const _SwatchChip({
    required this.swatch,
    required this.selected,
    required this.onTap,
  });

  final Swatch swatch;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: swatch.name,
      child: GestureDetector(
        onTap: onTap,
        // The label band is nearly transparent, so without this the bottom
        // third of the chip would not register a tap.
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: kSwatchChipWidth,
          height: kSwatchChipHeight,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? kSwatchSelectedBorder : Colors.transparent,
              width: kSwatchBorderWidth,
            ),
          ),
          child: Column(
            children: [
              SizedBox(
                height: kSwatchColorHeight - kSwatchBorderWidth * 2,
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: swatch.color,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(8),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      swatch.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        height: 1.1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
