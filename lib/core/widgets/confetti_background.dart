import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/verbena_theme.dart';

/// Fondo decorativo estático (confeti + 2 fuegos artificiales), reutilizado
/// en Onboarding, Home, PhotoSelect, Processing y Profile. Semilla fija (42):
/// mismas posiciones en cada apertura de pantalla, no es aleatorio por carga.
/// Se coloca como primer hijo de un Stack -- el contenido real de cada
/// pantalla va encima, con su propio fondo sólido, así que tapa lo que quede
/// debajo sin mezclarse visualmente. NO se usa en Paywall (necesita máxima
/// claridad para el precio/CTA) ni en Result (la foto generada debe ser la
/// única protagonista).
class ConfettiBackground extends StatelessWidget {
  const ConfettiBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(
      child: RepaintBoundary(
        child: CustomPaint(painter: _ConfettiPainter()),
      ),
    );
  }
}

class _ConfettiPiece {
  const _ConfettiPiece({
    required this.dx,
    required this.dy,
    required this.rotation,
    required this.color,
    this.rectSize,
    this.circleRadius,
  });

  final double dx;
  final double dy;
  final double rotation;
  final Color color;
  final Size? rectSize;
  final double? circleRadius;
}

class _ConfettiPainter extends CustomPainter {
  const _ConfettiPainter();

  static final List<_ConfettiPiece> _pieces = _generatePieces();

  static List<_ConfettiPiece> _generatePieces() {
    final random = math.Random(42);
    return List.generate(22, (i) {
      final color = i.isEven ? VerbenaColors.teal : VerbenaColors.terracotta;
      final dx = random.nextDouble();
      final dy = random.nextDouble();
      final rotation = random.nextDouble() * math.pi * 2;
      if (random.nextBool()) {
        final width = 7 + random.nextDouble();
        final height = 12 + random.nextDouble() * 2;
        return _ConfettiPiece(
          dx: dx,
          dy: dy,
          rotation: rotation,
          color: color,
          rectSize: Size(width, height),
        );
      }
      final radius = 4 + random.nextDouble();
      return _ConfettiPiece(
          dx: dx,
          dy: dy,
          rotation: rotation,
          color: color,
          circleRadius: radius);
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()..style = PaintingStyle.fill;
    for (final piece in _pieces) {
      fillPaint.color = piece.color.withValues(alpha: 0.4);
      canvas.save();
      canvas.translate(piece.dx * size.width, piece.dy * size.height);
      canvas.rotate(piece.rotation);
      final rectSize = piece.rectSize;
      if (rectSize != null) {
        canvas.drawRect(
          Rect.fromCenter(
              center: Offset.zero,
              width: rectSize.width,
              height: rectSize.height),
          fillPaint,
        );
      } else {
        canvas.drawCircle(Offset.zero, piece.circleRadius!, fillPaint);
      }
      canvas.restore();
    }

    _paintFirework(canvas, Offset(size.width * 0.85, size.height * 0.08),
        VerbenaColors.terracotta);
    _paintFirework(canvas, Offset(size.width * 0.12, size.height * 0.9),
        VerbenaColors.teal);
  }

  void _paintFirework(Canvas canvas, Offset center, Color color) {
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.4)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const radius = 13.0;
    for (var i = 0; i < 6; i++) {
      final angle = (math.pi / 3) * i;
      final end = Offset(center.dx + radius * math.cos(angle),
          center.dy + radius * math.sin(angle));
      canvas.drawLine(center, end, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) => false;
}
