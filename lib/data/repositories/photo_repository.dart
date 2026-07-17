import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/verified_photo.dart';
import '../providers/supabase_provider.dart';

class PhotoRepository {
  PhotoRepository(this._client);

  final SupabaseClient _client;

  /// Sube los bytes crudos de la foto a la Edge Function verify-photo.
  /// Se llama UNA VEZ por archivo exacto -- la función deduplica por hash y
  /// devuelve directamente el resultado cacheado si ya se verificó antes.
  /// Nunca descuenta crédito: eso lo hacen generate-catalog/generate-libertad
  /// una vez que este resultado es 'approved'.
  Future<VerifiedPhotoResult> verifyPhoto({
    required Uint8List bytes,
    required String contentType,
  }) async {
    final response = await _client.functions.invoke(
      'verify-photo',
      body: bytes,
      headers: {'Content-Type': contentType},
    );

    if (response.status != 200) {
      final data = response.data;
      final message = data is Map ? data['error']?.toString() : null;
      throw PhotoVerificationException(message ?? 'verify-photo failed (${response.status})');
    }

    return VerifiedPhotoResult.fromJson(response.data as Map<String, dynamic>);
  }
}

class PhotoVerificationException implements Exception {
  PhotoVerificationException(this.message);
  final String message;

  @override
  String toString() => message;
}

final photoRepositoryProvider = Provider<PhotoRepository>((ref) {
  return PhotoRepository(ref.watch(supabaseClientProvider));
});
