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
    this.secondPhotoBytes,
    this.secondContentType,
  }) : photoSessionId = null;

  const ProcessingArgs.fromSession({
    required this.source,
    required String this.photoSessionId,
    this.secondPhotoBytes,
    this.secondContentType,
  })  : photoBytes = null,
        contentType = null;

  final GenerationSource source;
  final Uint8List? photoBytes;
  final String? contentType;
  final String? photoSessionId;

  // Segunda foto opcional de modo Libertad (gpt-image-2 admite hasta 2
  // imágenes de referencia) -- siempre recién elegida (bytes), nunca
  // reutiliza "Mis fotos verificadas" como la primera, así que solo hace
  // falta un constructor común para ambas variantes de la foto principal.
  final Uint8List? secondPhotoBytes;
  final String? secondContentType;

  bool get needsVerification => photoSessionId == null;
  bool get hasSecondPhoto => secondPhotoBytes != null;
}
