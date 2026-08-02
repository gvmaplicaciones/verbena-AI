import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/navigation.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/models/mask_painter_args.dart';
import '../../../data/models/mask_prompt_args.dart';
import '../../../data/models/processing_args.dart';
import '../../../data/repositories/photo_repository.dart';

/// Pantalla de pintura de máscara — recibe una foto (bytes o sessionId) y
/// permite al usuario marcar con el dedo la zona a eliminar. El resultado es
/// un PNG blanco/negro (blanco = zona a borrar, negro = conservar) que viaja
/// a ProcessingScreen como `maskBytes` dentro de ProcessingArgs.
///
/// Independiente del modo: solo sabe recibir una foto y devolver una máscara.
/// La lógica de generación vive en ProcessingScreen y GenerationRepository.
class MaskPainterScreen extends ConsumerStatefulWidget {
  const MaskPainterScreen({super.key, required this.args});

  final MaskPainterArgs args;

  @override
  ConsumerState<MaskPainterScreen> createState() => _MaskPainterScreenState();
}

class _MaskPainterScreenState extends ConsumerState<MaskPainterScreen> {
  ui.Image? _image;
  bool _loading = true;
  String? _loadError;

  // Cada trazo es una lista de puntos en espacio de píxeles de la imagen
  // (no en coordenadas de widget). Se convierten al espacio del widget para
  // pintar y al espacio imagen para exportar.
  final List<List<Offset>> _strokes = [];
  List<Offset>? _currentStroke;

  // Radio del pincel en píxeles LÓGICOS dentro de la zona visible de la imagen
  double _brushRadius = 22.0;

  // Rect donde la imagen se renderiza dentro del widget del lienzo (se
  // recalcula en LayoutBuilder). Se usa tanto para convertir gestos como para
  // exportar la máscara al tamaño correcto.
  Rect _imageRect = Rect.zero;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final ui.Image image;
      if (widget.args.photoBytes != null) {
        final codec = await ui.instantiateImageCodec(widget.args.photoBytes!);
        final frame = await codec.getNextFrame();
        image = frame.image;
      } else {
        // Foto ya verificada: descarga a través de URL firmada
        final url = await ref
            .read(photoRepositoryProvider)
            .signedUrl(widget.args.storagePath!);
        final provider = NetworkImage(url);
        final completer = Completer<ui.Image>();
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, _) {
            if (!completer.isCompleted) completer.complete(info.image);
          },
          onError: (e, st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          },
        );
        provider.resolve(const ImageConfiguration()).addListener(listener);
        image = await completer.future;
      }
      if (!mounted) return;
      setState(() {
        _image = image;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = 'No se ha podido cargar la foto.';
        _loading = false;
      });
    }
  }

  // Rect donde la imagen se renderiza dentro de `widgetSize` con BoxFit.contain
  Rect _computeImageRect(Size widgetSize) {
    final img = _image!;
    final imgAspect = img.width / img.height;
    final wAspect = widgetSize.width / widgetSize.height;
    final double rW, rH;
    if (imgAspect > wAspect) {
      rW = widgetSize.width;
      rH = widgetSize.width / imgAspect;
    } else {
      rW = widgetSize.height * imgAspect;
      rH = widgetSize.height;
    }
    return Rect.fromLTWH(
      (widgetSize.width - rW) / 2,
      (widgetSize.height - rH) / 2,
      rW,
      rH,
    );
  }

  // Convierte un punto en espacio de widget al espacio de píxeles de la imagen.
  // Si el punto está fuera del imageRect, lo clampea al borde.
  Offset _widgetToImagePx(Offset widgetPt) {
    final img = _image!;
    final clamped = Offset(
      widgetPt.dx.clamp(_imageRect.left, _imageRect.right - 1),
      widgetPt.dy.clamp(_imageRect.top, _imageRect.bottom - 1),
    );
    return Offset(
      (clamped.dx - _imageRect.left) / _imageRect.width * img.width,
      (clamped.dy - _imageRect.top) / _imageRect.height * img.height,
    );
  }

  void _onPanStart(DragStartDetails d) {
    if (_image == null || _imageRect == Rect.zero) return;
    final pt = _widgetToImagePx(d.localPosition);
    final stroke = [pt];
    setState(() {
      _currentStroke = stroke;
      _strokes.add(stroke);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_currentStroke == null) return;
    final pt = _widgetToImagePx(d.localPosition);
    setState(() => _currentStroke!.add(pt));
  }

  void _onPanEnd(DragEndDetails _) => _currentStroke = null;

  void _onTapDown(TapDownDetails d) {
    if (_image == null || _imageRect == Rect.zero) return;
    final pt = _widgetToImagePx(d.localPosition);
    // Un toque puntual: dos puntos iguales para que el path tenga longitud
    setState(() => _strokes.add([pt, pt]));
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.removeLast());
  }

  void _clear() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.clear());
  }

  // Exporta la máscara como PNG al tamaño real de la imagen.
  // Blanco = zona a eliminar (lo que pintó el usuario).
  // Negro = zona a conservar (el fondo por defecto).
  Future<Uint8List> _exportMask() async {
    final img = _image!;
    final scaleX = img.width / _imageRect.width;
    final scaleY = img.height / _imageRect.height;
    // Radio del pincel escalado al espacio de píxeles de la imagen
    final brushPxRadius = _brushRadius * (scaleX + scaleY) / 2;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    );

    // Fondo negro = conservar todo por defecto
    canvas.drawRect(
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Paint()..color = const Color(0xFF000000),
    );

    final strokePaint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = brushPxRadius * 2;

    final dotPaint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill;

    for (final stroke in _strokes) {
      if (stroke.isEmpty) continue;
      // Círculo en el primer punto (cubre toques puntuales y suaviza extremos)
      canvas.drawCircle(stroke.first, brushPxRadius, dotPaint);
      if (stroke.length > 1) {
        final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
        for (final pt in stroke.skip(1)) {
          path.lineTo(pt.dx, pt.dy);
        }
        canvas.drawPath(path, strokePaint);
        canvas.drawCircle(stroke.last, brushPxRadius, dotPaint);
      }
    }

    final picture = recorder.endRecording();
    final maskImg = await picture.toImage(img.width, img.height);
    final byteData = await maskImg.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Future<void> _generate() async {
    if (_strokes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pinta primero la zona que quieres eliminar'),
        ),
      );
      return;
    }

    final maskBytes = await _exportMask();
    if (!mounted) return;

    // Todos los sub-modos por máscara pasan por un paso de texto antes de
    // Processing (ver MaskPromptScreen): "Añadir algo"/"Modificar algo" lo
    // exigen, "Eliminar algo" lo deja opcional (la intención ya está en lo
    // pintado, pero el usuario puede dar una pista extra sobre qué debería
    // haber en el fondo en su lugar).
    if (widget.args.source is AddElementSource ||
        widget.args.source is ModifyElementSource ||
        widget.args.source is RemoveElementSource) {
      final MaskPromptArgs promptArgs;
      if (widget.args.photoSessionId != null) {
        promptArgs = MaskPromptArgs.fromSession(
          source: widget.args.source,
          photoSessionId: widget.args.photoSessionId!,
          maskBytes: maskBytes,
        );
      } else {
        promptArgs = MaskPromptArgs.fromPhoto(
          source: widget.args.source,
          photoBytes: widget.args.photoBytes!,
          contentType: widget.args.contentType!,
          maskBytes: maskBytes,
        );
      }
      context.push(AppRoutes.maskPrompt, extra: promptArgs);
      return;
    }

    final ProcessingArgs args;
    if (widget.args.photoSessionId != null) {
      args = ProcessingArgs.fromSession(
        source: widget.args.source,
        photoSessionId: widget.args.photoSessionId!,
        maskBytes: maskBytes,
      );
    } else {
      args = ProcessingArgs.fromPhoto(
        source: widget.args.source,
        photoBytes: widget.args.photoBytes!,
        contentType: widget.args.contentType!,
        maskBytes: maskBytes,
      );
    }

    context.push(AppRoutes.processing, extra: args);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildBody()),
                _buildControls(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  (String, String) get _headerTexts => switch (widget.args.source) {
        AddElementSource() => (
            'Marca dónde quieres añadirlo',
            'Pinta con el dedo la zona donde quieres añadirlo',
          ),
        ModifyElementSource() => (
            'Marca lo que quieres cambiar',
            'Pinta con el dedo la zona que quieres modificar',
          ),
        _ => (
            'Selecciona lo que quieres borrar',
            'Pinta con el dedo la zona que quieres eliminar',
          ),
      };

  Widget _buildHeader() {
    final (title, subtitle) = _headerTexts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              VerbenaRoundIconButton(
                icon: const VerbenaBackChevronIcon(),
                onTap: () => context.safePop(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: VerbenaText.display(size: 18)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 3,
          color: VerbenaColors.teal,
        ),
      );
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _loadError!,
            textAlign: TextAlign.center,
            style: VerbenaText.body(size: 14.5, color: VerbenaColors.textMuted),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _imageRect = _computeImageRect(size);
        return GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onTapDown: _onTapDown,
          child: CustomPaint(
            size: size,
            painter: _MaskOverlayPainter(
              image: _image!,
              imageRect: _imageRect,
              strokes: _strokes,
              brushRadius: _brushRadius,
            ),
          ),
        );
      },
    );
  }

  Widget _buildControls() {
    final hasStrokes = _strokes.isNotEmpty;
    // Diámetro visual del indicador de pincel (escala de 6 a 26 lógicos)
    final indicatorSize = (_brushRadius / 60 * 20 + 6).clamp(6.0, 26.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: VerbenaColors.card,
        border: Border(
          top: BorderSide(
            color: VerbenaColors.textDark.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Slider de tamaño de pincel
          Row(
            children: [
              const Icon(Icons.brush_rounded,
                  size: 18, color: VerbenaColors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Slider(
                  value: _brushRadius,
                  min: 8,
                  max: 60,
                  activeColor: VerbenaColors.teal,
                  inactiveColor:
                      VerbenaColors.textDark.withValues(alpha: 0.15),
                  onChanged: (v) => setState(() => _brushRadius = v),
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: Center(
                  child: Container(
                    width: indicatorSize,
                    height: indicatorSize,
                    decoration: const BoxDecoration(
                      color: VerbenaColors.teal,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Acciones
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: hasStrokes ? _undo : null,
                icon: const Icon(Icons.undo_rounded, size: 18),
                label: const Text('Deshacer'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: VerbenaColors.textDark,
                  disabledForegroundColor:
                      VerbenaColors.textDark.withValues(alpha: 0.3),
                  side: BorderSide(
                      color:
                          VerbenaColors.textDark.withValues(alpha: 0.25)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: hasStrokes ? _clear : null,
                icon: const Icon(Icons.layers_clear_rounded, size: 18),
                label: const Text('Limpiar'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: VerbenaColors.terracotta,
                  disabledForegroundColor:
                      VerbenaColors.terracotta.withValues(alpha: 0.3),
                  side: BorderSide(
                      color: VerbenaColors.terracotta
                          .withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                ),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: _generate,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 22, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  textStyle: VerbenaText.display(
                      size: 14,
                      color: VerbenaColors.background,
                      letterSpacing: 0.4),
                ),
                child: const Text('GENERAR'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MaskOverlayPainter extends CustomPainter {
  const _MaskOverlayPainter({
    required this.image,
    required this.imageRect,
    required this.strokes,
    required this.brushRadius,
  });

  final ui.Image image;
  final Rect imageRect;
  final List<List<Offset>> strokes;
  final double brushRadius;

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Imagen a tamaño completo del rect calculado
    paintImage(
      canvas: canvas,
      rect: imageRect,
      image: image,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
    );

    // 2. Velo oscuro sobre la imagen (contrasta con la máscara blanca)
    canvas.drawRect(
      imageRect,
      Paint()..color = Colors.black.withValues(alpha: 0.3),
    );

    if (strokes.isEmpty) return;

    // 3. Pinceladas blancas semitransparentes = zona marcada para eliminar
    final scaleX = imageRect.width / image.width;
    final scaleY = imageRect.height / image.height;

    final strokePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = brushRadius * 2;

    final dotPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.fill;

    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      final first = _toWidget(stroke.first, scaleX, scaleY);
      canvas.drawCircle(first, brushRadius, dotPaint);
      if (stroke.length > 1) {
        final path = Path()..moveTo(first.dx, first.dy);
        for (final pt in stroke.skip(1)) {
          path.lineTo(_toWidget(pt, scaleX, scaleY).dx,
              _toWidget(pt, scaleX, scaleY).dy);
        }
        canvas.drawPath(path, strokePaint);
        canvas.drawCircle(_toWidget(stroke.last, scaleX, scaleY), brushRadius, dotPaint);
      }
    }
  }

  Offset _toWidget(Offset imgPx, double sx, double sy) {
    return Offset(
      imgPx.dx * sx + imageRect.left,
      imgPx.dy * sy + imageRect.top,
    );
  }

  @override
  bool shouldRepaint(_MaskOverlayPainter old) => true;
}
