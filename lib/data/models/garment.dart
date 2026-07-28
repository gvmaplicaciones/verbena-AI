import 'dart:typed_data';

/// Fila de `garments` -- una prenda guardada en el Armario (solo socios, ver
/// ProfileScreen). `storagePath` nulo significa "purgada" (ver
/// expireSubscription/purgeGarments en el backend): la fila se conserva pero
/// ya no hay archivo, así que no debe ofrecerse como elegible en el picker.
class Garment {
  final String id;
  final String? storagePath;
  final DateTime createdAt;

  const Garment({
    required this.id,
    required this.storagePath,
    required this.createdAt,
  });

  factory Garment.fromJson(Map<String, dynamic> json) => Garment(
        id: json['id'] as String,
        storagePath: json['storage_path'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

/// Una prenda elegida para el modo "Probar un look", de uno de dos orígenes
/// posibles -- ver generate-try-on, que las trata como dos listas separadas
/// (garmentPhotoSessionIds vs garmentIds).
sealed class GarmentPick {
  const GarmentPick();
}

/// Prenda nueva (cámara/galería), aún sin verificar -- ProcessingScreen la
/// pasa por verify-photo antes de generar, igual que photoBytes/secondPhotoBytes.
class GarmentPickBytes extends GarmentPick {
  const GarmentPickBytes({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

/// Prenda ya guardada en el Armario -- ya moderada al subirla, solo se
/// revalida su propiedad en el backend, sin volver a verificar.
class GarmentPickWardrobe extends GarmentPick {
  const GarmentPickWardrobe({required this.garmentId, this.storagePath});

  final String garmentId;
  final String? storagePath;
}
