import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/verbena_theme.dart';

/// Slider antes/después reutilizable: dos imágenes superpuestas (antes a la
/// izquierda del tirador, después a la derecha), con un tirador central que
/// el usuario arrastra para revelar más de una u otra -- estilo el
/// comparador del playground de Replicate. Compartido por ResultScreen para
/// TODOS los modos, no solo "Eliminar fondo".
///
/// [checkerboardAfter] pinta un patrón de cuadros detrás de la imagen
/// "después" (no de la "antes") -- solo tiene sentido cuando esa imagen
/// puede tener transparencia real (modo "Eliminar fondo"), para poder
/// distinguir "sin fondo" de "fondo blanco".
///
/// La imagen "antes" admite [beforeUrl] (foto ya subida, con sesión) o
/// [beforeBytes] (modos que omiten verify-photo -- RemoveBackground,
/// EnhanceQuality -- donde la foto original no se sube a Storage y solo
/// existe en memoria). Se exige exactamente una de las dos.
class BeforeAfterSlider extends StatefulWidget {
  const BeforeAfterSlider({
    super.key,
    this.beforeUrl,
    this.beforeBytes,
    required this.afterUrl,
    this.checkerboardAfter = false,
  }) : assert(beforeUrl != null || beforeBytes != null,
            'BeforeAfterSlider requiere beforeUrl o beforeBytes');

  final String? beforeUrl;
  final Uint8List? beforeBytes;
  final String afterUrl;
  final bool checkerboardAfter;

  @override
  State<BeforeAfterSlider> createState() => _BeforeAfterSliderState();
}

class _BeforeAfterSliderState extends State<BeforeAfterSlider> {
  double _position = 0.5;

  void _updatePosition(double localX, double width) {
    if (width <= 0) return;
    setState(() => _position = (localX / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) =>
              _updatePosition(details.localPosition.dx, width),
          onTapDown: (details) =>
              _updatePosition(details.localPosition.dx, width),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRect(
                clipper: _RevealClipper(0, _position),
                child: widget.beforeBytes != null
                    ? Image.memory(widget.beforeBytes!, fit: BoxFit.contain)
                    : CachedNetworkImage(
                        imageUrl: widget.beforeUrl!,
                        fit: BoxFit.contain,
                        placeholder: (context, url) => const Center(
                            child: CircularProgressIndicator(
                                color: Colors.white)),
                      ),
              ),
              if (widget.checkerboardAfter)
                ClipRect(
                  clipper: _RevealClipper(_position, 1),
                  child: const _CheckerboardBackground(),
                ),
              ClipRect(
                clipper: _RevealClipper(_position, 1),
                child: CachedNetworkImage(
                  imageUrl: widget.afterUrl,
                  fit: BoxFit.contain,
                  placeholder: (context, url) => const Center(
                      child: CircularProgressIndicator(color: Colors.white)),
                ),
              ),
              Positioned(
                left: width * _position - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: Colors.white),
              ),
              Positioned(
                left: (width * _position - 18).clamp(0.0, width - 36),
                top: 0,
                bottom: 0,
                child: const Center(child: _DragHandle()),
              ),
              const Positioned(
                  top: 12, left: 12, child: _SliderLabel('ANTES')),
              const Positioned(
                  top: 12, right: 12, child: _SliderLabel('DESPUÉS')),
            ],
          ),
        );
      },
    );
  }
}

class _SliderLabel extends StatelessWidget {
  const _SliderLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: VerbenaText.display(size: 11, color: Colors.white)
            .copyWith(letterSpacing: 0.5),
      ),
    );
  }
}

/// Recorta el rectángulo horizontal entre [start] y [end] (fracciones 0-1 del
/// ancho) -- se usa dos veces con extremos complementarios para partir la
/// imagen "antes" y la "después" a ambos lados del tirador.
class _RevealClipper extends CustomClipper<Rect> {
  const _RevealClipper(this.start, this.end);

  final double start;
  final double end;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(size.width * start, 0, size.width * end, size.height);

  @override
  bool shouldReclip(covariant _RevealClipper oldClipper) =>
      oldClipper.start != start || oldClipper.end != end;
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: VerbenaColors.teal, width: 2),
        boxShadow: const [
          BoxShadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.compare_arrows_rounded,
          size: 18, color: VerbenaColors.teal),
    );
  }
}

/// Patrón de cuadros estándar para indicar transparencia -- estándar visual
/// de cualquier editor de imágenes, no blanco liso (que se confundiría con
/// "quitó el fondo y lo dejó blanco").
class _CheckerboardBackground extends StatelessWidget {
  const _CheckerboardBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _CheckerboardPainter(), size: Size.infinite);
  }
}

class _CheckerboardPainter extends CustomPainter {
  const _CheckerboardPainter();

  static const cellSize = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final light = Paint()..color = const Color(0xFFE8E8E8);
    final dark = Paint()..color = const Color(0xFFC4C4C4);
    canvas.drawRect(Offset.zero & size, light);
    for (double y = 0; y < size.height; y += cellSize) {
      for (double x = 0; x < size.width; x += cellSize) {
        final col = (x / cellSize).floor();
        final row = (y / cellSize).floor();
        if ((col + row).isOdd) {
          canvas.drawRect(Rect.fromLTWH(x, y, cellSize, cellSize), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerboardPainter oldDelegate) => false;
}
