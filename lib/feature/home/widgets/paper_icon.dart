import 'dart:math' as math;

import 'package:flutter/material.dart';

class PaperIcon extends StatelessWidget {
  final double mmPaperHeight;
  final double mmPaperWidth;
  const PaperIcon({
    super.key,
    required this.mmPaperHeight,
    required this.mmPaperWidth,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _PaperIconPainter(
      context: context,
      mmPaperHeight: mmPaperHeight,
      mmPaperWidth: mmPaperWidth,
    ),
  );
}

class _PaperIconPainter extends CustomPainter {
  final double mmPaperHeight;
  final double mmPaperWidth;
  final BuildContext context;
  double scaleFactor = -1;
  final double marginFactor = 0.1; // Fator de margem de 10%

  _PaperIconPainter({
    required this.context,
    required this.mmPaperHeight,
    required this.mmPaperWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (scaleFactor == -1) {
      final maxPaperSize = math.max<double>(mmPaperHeight, mmPaperWidth);
      final pxIconSize = math.min(size.height, size.width);
      scaleFactor = (pxIconSize / maxPaperSize) * (1 - marginFactor);
    }

    final rectWidth = mmPaperWidth * scaleFactor;
    final rectHeight = mmPaperHeight * scaleFactor;

    final leftMargin = (size.width - rectWidth) / 2;
    final topMargin = (size.height - rectHeight) / 2;

    final Rect paperRect = Rect.fromLTWH(
      leftMargin,
      topMargin,
      rectWidth,
      rectHeight,
    );

    canvas.drawRect(
      paperRect,
      Paint()
        ..color = Theme.of(context).hintColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  // Não será necessário desenhar mais de uma vez um ícone que não será redimensionado
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
