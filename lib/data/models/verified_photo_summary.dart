/// Fila de `verified_photos` con `is_persisted = true` -- las que alimentan
/// la galería de "Mis fotos verificadas" (solo socios, ver perfil y
/// PhotoSelect). Las efímeras (no persistidas) nunca llegan al cliente.
class VerifiedPhotoSummary {
  final String id;
  final String storagePath;
  final DateTime createdAt;

  const VerifiedPhotoSummary({
    required this.id,
    required this.storagePath,
    required this.createdAt,
  });

  factory VerifiedPhotoSummary.fromJson(Map<String, dynamic> json) => VerifiedPhotoSummary(
        id: json['id'] as String,
        storagePath: json['storage_path'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}
