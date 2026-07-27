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
    this.secondPhotoSessionId,
    this.maskBytes,
  }) : photoSessionId = null;

  const ProcessingArgs.fromSession({
    required this.source,
    required String this.photoSessionId,
    this.secondPhotoBytes,
    this.secondContentType,
    this.secondPhotoSessionId,
    this.maskBytes,
  })  : photoBytes = null,
        contentType = null;

  final GenerationSource source;
  final Uint8List? photoBytes;
  final String? contentType;
  final String? photoSessionId;

  // Segunda foto opcional (gpt-image-2 admite hasta 2 imágenes de
  // referencia): bytes si se acaba de elegir de cámara/galería (hace falta
  // verificarla en ProcessingScreen), o secondPhotoSessionId si ya viene de
  // "Mis fotos verificadas" -- mismo patrón que photoBytes/photoSessionId
  // para la foto principal.
  final Uint8List? secondPhotoBytes;
  final String? secondContentType;
  final String? secondPhotoSessionId;

  // Máscara pintada por el usuario en MaskPainterScreen (PNG en
  // blanco/negro): blanco = zona marcada, negro = zona a conservar. Presente
  // cuando source es RemoveElementSource(mode: .mask), AddElementSource(mode:
  // .mask) o ModifyElementSource -- el resto de modos lo ignoran.
  final Uint8List? maskBytes;

  bool get needsVerification => photoSessionId == null;
  bool get hasSecondPhoto =>
      secondPhotoBytes != null || secondPhotoSessionId != null;
}
