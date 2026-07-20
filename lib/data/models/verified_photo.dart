enum VerifiedPhotoStatus { approved, rejected, appealed }

VerifiedPhotoStatus _statusFromString(String value) => switch (value) {
      'approved' => VerifiedPhotoStatus.approved,
      'rejected' => VerifiedPhotoStatus.rejected,
      'appealed' => VerifiedPhotoStatus.appealed,
      _ => throw ArgumentError('unknown verified_photo status: $value'),
    };

/// Resultado de la llamada a la Edge Function verify-photo.
class VerifiedPhotoResult {
  final VerifiedPhotoStatus status;
  final String verifiedPhotoId;
  final String? photoSessionId;
  final String? reason;
  // No bloquea nada, la foto queda aprobada igual -- 'glasses_detected' es el
  // único valor que devuelve verify-photo hoy.
  final String? warning;

  const VerifiedPhotoResult({
    required this.status,
    required this.verifiedPhotoId,
    this.photoSessionId,
    this.reason,
    this.warning,
  });

  bool get hasGlassesWarning => warning == 'glasses_detected';

  factory VerifiedPhotoResult.fromJson(Map<String, dynamic> json) => VerifiedPhotoResult(
        status: _statusFromString(json['status'] as String),
        verifiedPhotoId: json['verifiedPhotoId'] as String,
        photoSessionId: json['photoSessionId'] as String?,
        reason: json['reason'] as String?,
        warning: json['warning'] as String?,
      );
}
