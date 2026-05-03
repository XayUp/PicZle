import 'package:flutter/material.dart';
import 'package:piczle/feature/home/widgets/paper_icon.dart';

class PaperPreset {
  final String name;
  final double width;
  final double height;

  const PaperPreset(this.name, this.width, this.height);
}

class PaperPresetDrop extends StatelessWidget {
  final Function(double w, double h) onItemSelected;
  final List<PaperPreset> presets;
  late final Widget _itemSelected;

  PaperPresetDrop({
    super.key,
    this.presets = const [PaperPreset('A4', 210, 297)],
    required this.onItemSelected,
  }) {
    _itemSelected = _buildPresetItem(presets.first);
  }

  @override
  Widget build(BuildContext context) {
    return _buildPresetMenu();
  }

  Widget _buildPresetItem(PaperPreset preset) {
    return Row(
      children: [
        SizedBox.square(
          dimension: 24,
          child: PaperIcon(
            mmPaperHeight: preset.height,
            mmPaperWidth: preset.width,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          textAlign: TextAlign.center,
          "${preset.name} (${preset.width.toInt()}x${preset.height.toInt()} mm)",
        ),
      ],
    );
  }

  Widget _buildPresetMenu() {
    return PopupMenuButton<PaperPreset>(
      //icon: const Icon(Icons.straighten), // Ícone de régua/dimensões
      tooltip: "Tamanhos Padrão",
      onSelected: (PaperPreset preset) {
        _itemSelected = _buildPresetItem(preset);
        onItemSelected(preset.width, preset.height);
      },
      itemBuilder: (BuildContext context) {
        return presets.map((PaperPreset preset) {
          return PopupMenuItem<PaperPreset>(
            value: preset,
            child: _buildPresetItem(preset),
          );
        }).toList();
      },
      //icon: const Icon(Icons.straighten), // Ícone de régua/dimensões
      child: _itemSelected,
    );
  }
}
