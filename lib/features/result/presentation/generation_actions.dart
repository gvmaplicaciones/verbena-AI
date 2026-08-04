import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';

/// Botones de compartir (WhatsApp) y guardar reutilizables desde ResultScreen
/// y desde el detalle de "Mis creaciones" en Perfil. Gestiona su propio estado
/// de carga — el widget padre no necesita saber cuándo está ocupado.
class GenerationShareActions extends StatefulWidget {
  const GenerationShareActions({
    super.key,
    required this.resultUrl,
    required this.generationId,
  });

  final String resultUrl;
  final String generationId;

  @override
  State<GenerationShareActions> createState() => _GenerationShareActionsState();
}

class _GenerationShareActionsState extends State<GenerationShareActions> {
  bool _busy = false;

  Future<Uint8List> _downloadResultBytes() async {
    final (bytes, _) = await _downloadResultBytesWithExtension();
    return bytes;
  }

  /// Descarga los bytes junto con la extensión real del resultado a partir
  /// del Content-Type servido -- no se puede asumir .jpg para todos los
  /// modos: "Eliminar fondo" sirve PNG con canal alfa, y compartirlo como
  /// .jpg confundiría al receptor sobre el tipo de archivo aunque los bytes
  /// en sí sean correctos.
  Future<(Uint8List, String)> _downloadResultBytesWithExtension() async {
    final request = await HttpClient().getUrl(Uri.parse(widget.resultUrl));
    final response = await request.close();
    final extension = response.headers.value('content-type') == 'image/png' ? 'png' : 'jpg';
    final bytes = await consolidateHttpClientResponseBytes(response);
    return (bytes, extension);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sendWhatsapp() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final (bytes, extension) = await _downloadResultBytesWithExtension();
      final tempFile = File(
          '${Directory.systemTemp.path}/verbenai_${widget.generationId}.$extension');
      await tempFile.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(tempFile.path)],
        text: 'Mira lo que me he hecho con VerbenAI 👀',
      );
    } catch (e, st) {
      // Reportado: en iOS el botón "no hace nada" -- GUARDAR (misma descarga
      // previa) funciona bien, así que el fallo está en escribir el archivo
      // temporal o en Share.shareXFiles, no en la descarga. Sin captura aquí
      // no había forma de ver el error real (2026-08-04).
      developer.log('whatsapp share failed: generationId=${widget.generationId}',
          name: 'GenerationShareActions', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st,
          hint: Hint.withMap(
              {'stage': 'share_whatsapp', 'generationId': widget.generationId})));
      _showSnack('No hemos podido compartir la imagen.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveImage() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final hasAccess = await Gal.hasAccess() || await Gal.requestAccess();
      if (!hasAccess) {
        _showSnack('Necesitamos acceso a tus fotos para guardar la imagen.');
        return;
      }
      final bytes = await _downloadResultBytes();
      await Gal.putImageBytes(
        bytes,
        name: 'verbenai_${widget.generationId}',
        album: 'VerbenAI',
      );
      _showSnack('Imagen guardada en tu galería.');
    } catch (_) {
      _showSnack('No hemos podido guardar la imagen.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      absorbing: _busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _sendWhatsapp,
              style: ElevatedButton.styleFrom(
                backgroundColor: VerbenaColors.whatsappGreen,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const VerbenaWhatsappIcon(size: 20),
                  const SizedBox(width: 10),
                  Text(
                    'ENVIAR POR WHATSAPP',
                    style: VerbenaText.display(
                        size: 16, color: Colors.white, letterSpacing: 0.4),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _saveImage,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: VerbenaColors.teal, width: 2),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            child: Text(
              'GUARDAR',
              style: VerbenaText.display(
                  size: 12.5, color: VerbenaColors.teal, letterSpacing: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}
