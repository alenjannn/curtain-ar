import 'package:flutter/material.dart';
import '../models/swatch.dart';

class SwatchSelector extends StatelessWidget {
  final List<Swatch> swatches;
  final Swatch? selectedSwatch;
  final ValueChanged<Swatch> onSwatchSelected;

  const SwatchSelector({
    super.key,
    required this.swatches,
    this.selectedSwatch,
    required this.onSwatchSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: swatches.length,
        itemBuilder: (context, index) {
          final swatch = swatches[index];
          final isSelected = swatch.id == selectedSwatch?.id;
          return GestureDetector(
            onTap: () => onSwatchSelected(swatch),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected
                      ? Theme.of(context).primaryColor
                      : Colors.transparent,
                  width: 3,
                ),
              ),
              child: CircleAvatar(
                radius: 24,
                backgroundImage: AssetImage(swatch.texturePath),
              ),
            ),
          );
        },
      ),
    );
  }
}
