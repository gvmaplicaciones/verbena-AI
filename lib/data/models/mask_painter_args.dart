import 'dart:typed_data';

import 'generation_source.dart';

/// Payload que PhotoSelect pasa a MaskPainterScreen. Dos variantes:
/// `.fromPhoto` (foto recién elegida, bytes disponibles localmente) y
/// `.fromSession` (foto ya verificada -- MaskPainterScreen la descarga desde
/// Storage para mostrarla, y ProcessingScreen usa el sessionId para que la
/// Edge Function la descargue también en el servidor).
class MaskPainterArgs {
  const MaskPainterArgs.fromPhoto({
    required this.source,
    required Uint8List this.photoBytes,
    required String this.contentType,
  })  : photoSessionId = null,
        storagePath = null;

  const MaskPainterArgs.fromSession({
    required this.source,
    required String this.photoSessionId,
    required String this.storagePath,
  })  : photoBytes = null,
        contentType = null;

  final GenerationSource source;

  final Uint8List? photoBytes;
  final String? contentType;

  final String? photoSessionId;
  final String? storagePath;
}
