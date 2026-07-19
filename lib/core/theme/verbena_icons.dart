import 'package:flutter/material.dart';

import 'verbena_theme.dart';

/// Iconos calcados a mano del handoff (paths SVG exactos, viewBox 24x24
/// salvo que se indique lo contrario) — no se usa un paquete de SVG para
/// tener control pixel a pixel a los tamaños pequeños del diseño.
class VerbenaCameraIcon extends StatelessWidget {
  const VerbenaCameraIcon({
    super.key,
    this.size = 44,
    this.color = VerbenaColors.background,
    this.withViewfinderBump = true,
  });

  final double size;
  final Color color;
  // El icono de cámara del onboarding lleva un pequeño rectángulo de
  // visor arriba; el de PhotoSelect (misma cámara, más pequeña) no -- dos
  // variantes del mismo SVG base en el handoff, no un error de omisión.
  final bool withViewfinderBump;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _CameraPainter(color, withViewfinderBump));
  }
}

class _CameraPainter extends CustomPainter {
  _CameraPainter(this.color, this.withViewfinderBump);

  final Color color;
  final bool withViewfinderBump;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(2, 7, 20, 14), const Radius.circular(3)),
      stroke,
    );
    canvas.drawCircle(const Offset(12, 14), 4, stroke);
    if (withViewfinderBump) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(8, 4, 8, 3), const Radius.circular(1)),
        fill,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CameraPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.withViewfinderBump != withViewfinderBump;
}

class VerbenaFacesIcon extends StatelessWidget {
  const VerbenaFacesIcon({super.key, this.size = 44, this.color = VerbenaColors.background});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _FacesPainter(color));
  }
}

class _FacesPainter extends CustomPainter {
  _FacesPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);

    final fill = Paint()..color = color..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawCircle(const Offset(8, 9), 3, fill);
    canvas.drawCircle(const Offset(16, 9), 3, fill);

    final arc = Path()
      ..moveTo(4, 20)
      ..cubicTo(4, 16, 7, 14, 12, 14)
      ..cubicTo(17, 14, 20, 16, 20, 20);
    canvas.drawPath(arc, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FacesPainter oldDelegate) => oldDelegate.color != color;
}

class VerbenaCheckmarkIcon extends StatelessWidget {
  const VerbenaCheckmarkIcon({super.key, this.size = 44, this.color = VerbenaColors.background});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _CheckmarkPainter(color));
  }
}

class _CheckmarkPainter extends CustomPainter {
  _CheckmarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawCircle(const Offset(12, 12), 9, stroke);

    final check = Path()
      ..moveTo(8, 13)
      ..lineTo(10.5, 15.5)
      ..lineTo(16, 9);
    canvas.drawPath(check, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CheckmarkPainter oldDelegate) => oldDelegate.color != color;
}

class VerbenaPersonIcon extends StatelessWidget {
  const VerbenaPersonIcon({super.key, this.size = 17, this.color = VerbenaColors.background});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _PersonPainter(color));
  }
}

class _PersonPainter extends CustomPainter {
  _PersonPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);

    final fill = Paint()..color = color..style = PaintingStyle.fill;

    canvas.drawCircle(const Offset(12, 8), 4, fill);

    final shoulders = Path()
      ..moveTo(4, 20)
      ..cubicTo(4, 15.6, 7.6, 13, 12, 13)
      ..cubicTo(16.4, 13, 20, 15.6, 20, 20)
      ..close();
    canvas.drawPath(shoulders, fill);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PersonPainter oldDelegate) => oldDelegate.color != color;
}

class VerbenaGalleryIcon extends StatelessWidget {
  const VerbenaGalleryIcon({super.key, this.size = 22, this.color = VerbenaColors.background});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _GalleryPainter(color));
  }
}

class _GalleryPainter extends CustomPainter {
  _GalleryPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(2, 3, 20, 18), const Radius.circular(3)),
      stroke,
    );
    canvas.drawCircle(const Offset(8, 9), 2, fill);
    final mountains = Path()
      ..moveTo(3, 17)
      ..lineTo(8, 12)
      ..lineTo(12, 16)
      ..lineTo(15, 13)
      ..lineTo(21, 19);
    canvas.drawPath(mountains, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GalleryPainter oldDelegate) => oldDelegate.color != color;
}

class VerbenaLockIcon extends StatelessWidget {
  const VerbenaLockIcon({super.key, this.size = 20, this.color = VerbenaColors.background});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _LockPainter(color));
  }
}

class _LockPainter extends CustomPainter {
  _LockPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(5, 10, 14, 10), const Radius.circular(2)),
      stroke,
    );
    final shackle = Path()
      ..moveTo(8, 10)
      ..lineTo(8, 7)
      ..arcToPoint(const Offset(16, 7), radius: const Radius.circular(4))
      ..lineTo(16, 10);
    canvas.drawPath(shackle, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LockPainter oldDelegate) => oldDelegate.color != color;
}

class VerbenaWhatsappIcon extends StatelessWidget {
  const VerbenaWhatsappIcon({super.key, this.size = 20, this.color = Colors.white});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _WhatsappPainter(color));
  }
}

class _WhatsappPainter extends CustomPainter {
  _WhatsappPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);

    final bgFill = Paint()..color = color.withValues(alpha: 0.18)..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(12, 12), 10, bgFill);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final bubble = Path()
      ..moveTo(8, 15.5)
      ..cubicTo(8, 12.5, 10.2, 10.3, 12.8, 10.3)
      ..cubicTo(15.4, 10.3, 17.4, 12.3, 17.4, 14.7)
      ..cubicTo(17.4, 17, 15.5, 18.8, 13, 18.8)
      ..cubicTo(12.2, 18.8, 11.5, 18.6, 10.8, 18.3)
      ..lineTo(8, 19)
      ..lineTo(8.6, 16.3)
      ..cubicTo(8.2, 15.7, 8, 15.1, 8, 14.4)
      ..lineTo(8, 14.5)
      ..close();
    canvas.drawPath(bubble, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WhatsappPainter oldDelegate) => oldDelegate.color != color;
}

class VerbenaChevronRightIcon extends StatelessWidget {
  const VerbenaChevronRightIcon({
    super.key,
    this.width = 8,
    this.height = 13,
    this.color = const Color(0x662B2118),
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(width, height), painter: _ChevronRightPainter(color));
  }
}

class _ChevronRightPainter extends CustomPainter {
  _ChevronRightPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 8, size.height / 13);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final chevron = Path()
      ..moveTo(1, 1)
      ..lineTo(7, 6.5)
      ..lineTo(1, 12);
    canvas.drawPath(chevron, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ChevronRightPainter oldDelegate) => oldDelegate.color != color;
}

class VerbenaBackChevronIcon extends StatelessWidget {
  const VerbenaBackChevronIcon({
    super.key,
    this.width = 10,
    this.height = 16,
    this.color = VerbenaColors.textDark,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(width, height), painter: _BackChevronPainter(color));
  }
}

class _BackChevronPainter extends CustomPainter {
  _BackChevronPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 10, size.height / 16);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final chevron = Path()
      ..moveTo(8, 1)
      ..lineTo(1.5, 8)
      ..lineTo(8, 15);
    canvas.drawPath(chevron, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BackChevronPainter oldDelegate) => oldDelegate.color != color;
}

class VerbenaCloseIcon extends StatelessWidget {
  const VerbenaCloseIcon({super.key, this.size = 14, this.color = VerbenaColors.textDark});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _ClosePainter(color));
  }
}

class _ClosePainter extends CustomPainter {
  _ClosePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(const Offset(5, 5), const Offset(19, 19), stroke);
    canvas.drawLine(const Offset(19, 5), const Offset(5, 19), stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ClosePainter oldDelegate) => oldDelegate.color != color;
}

/// Botón circular reutilizado en 4 pantallas (PhotoSelect, Paywall, Result,
/// Profile) para "volver"/"cerrar" -- mismo bg translúcido rgba(43,33,24,0.08)
/// y tamaño 34x34 en el handoff salvo Result, que usa un overlay oscuro sobre
/// la imagen (bg distinto, se pasa explícito).
class VerbenaRoundIconButton extends StatelessWidget {
  const VerbenaRoundIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.diameter = 34,
    this.background = const Color(0x142B2118),
  });

  final Widget icon;
  final VoidCallback onTap;
  final double diameter;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(color: background, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: icon,
      ),
    );
  }
}
