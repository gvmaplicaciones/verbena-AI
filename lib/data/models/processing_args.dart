import 'dart:typed_data';

import 'generation_source.dart';

/// Payload que PhotoSelect pasa a Processing (`extra` de go_router): de dónde
/// sale la generación (plantilla o prompt libre) + la foto a usar. Dos modos:
/// `.fromPhoto` (foto recién elegida, hace falta verify-photo) y
/// `.fromSession` (foto ya verificada -- "Mis fotos verificadas" o "Otra
/// vez" desde Result -- Processing se salta el paso de verificación).
class ProcessingArgs {
  const ProcessingArgs.fromPhoto({
    required this.source,
    required Uint8List this.photoBytes,
    required String this.contentType,
  }) : photoSessionId = null;

  const ProcessingArgs.fromSession({
    required this.source,
    required String this.photoSessionId,
  })  : photoBytes = null,
        contentType = null;

  final GenerationSource source;
  final Uint8List? photoBytes;
  final String? contentType;
  final String? photoSessionId;

  bool get needsVerification => photoSessionId == null;
}
