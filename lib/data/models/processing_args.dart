import 'dart:typed_data';

import 'garment.dart';
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
    this.garmentPicks,
  }) : photoSessionId = null;

  const ProcessingArgs.fromSession({
    required this.source,
    required String this.photoSessionId,
    this.secondPhotoBytes,
    this.secondContentType,
    this.secondPhotoSessionId,
    this.garmentPicks,
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

  // Prendas del modo "Probar un look" (TryOnSource), 1-4 -- cada una es o
  // bien bytes recién elegidos (hace falta verify-photo en ProcessingScreen)
  // o bien una prenda ya guardada en el Armario (ya verificada, se manda
  // directa como garmentId). El resto de modos lo ignoran.
  final List<GarmentPick>? garmentPicks;

  bool get needsVerification => photoSessionId == null;
  bool get hasSecondPhoto =>
      secondPhotoBytes != null || secondPhotoSessionId != null;
}
