import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/verified_photo.dart';
import '../models/verified_photo_summary.dart';
import '../providers/supabase_provider.dart';

const _contentTypeByExtension = {
  'jpg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
};

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

  /// Fotos verificadas persistidas (`is_persisted = true`, solo existe para
  /// socios) que alimentan "Mis fotos verificadas" en PhotoSelect y Perfil.
  Future<List<VerifiedPhotoSummary>> listPersistedPhotos() async {
    final userId = _client.auth.currentUser!.id;
    final rows = await _client
        .from('verified_photos')
        .select('id, storage_path, created_at')
        .eq('user_id', userId)
        .eq('is_persisted', true)
        .order('created_at', ascending: false);
    return rows.map(VerifiedPhotoSummary.fromJson).toList();
  }

  /// Da un photoSessionId fresco para una foto ya aprobada y guardada
  /// (`is_persisted`), sin resubir bytes ni volver a pasar por moderación --
  /// usado por "Usa una foto reciente" en PhotoSelect para saltarse la
  /// verificación por completo.
  Future<String> ensurePhotoSession(String verifiedPhotoId) async {
    final response = await _client.functions.invoke(
      'ensure-photo-session',
      body: {'verifiedPhotoId': verifiedPhotoId},
    );

    if (response.status != 200) {
      final data = response.data;
      final message = data is Map ? data['error']?.toString() : null;
      throw PhotoVerificationException(message ?? 'ensure-photo-session failed (${response.status})');
    }

    return (response.data as Map<String, dynamic>)['photoSessionId'] as String;
  }

  String contentTypeForPath(String storagePath) {
    final ext = storagePath.split('.').last.toLowerCase();
    return _contentTypeByExtension[ext] ?? 'image/jpeg';
  }

  Future<String> signedUrl(String storagePath) {
    return _client.storage.from('verified-photos').createSignedUrl(storagePath, 3600);
  }

  /// URL firmada de la foto "antes" (original) de una generación, resuelta
  /// desde el mismo photoSessionId que ya viaja en ResultArgs -- alimenta el
  /// slider antes/después de ResultScreen sin plumbing nuevo. photo_sessions
  /// y verified_photos tienen RLS de solo lectura del propio usuario, así que
  /// el embed anidado de PostgREST basta sin pasar por una Edge Function.
  Future<String> originalPhotoUrlForSession(String photoSessionId) async {
    final row = await _client
        .from('photo_sessions')
        .select('verified_photos(storage_path)')
        .eq('id', photoSessionId)
        .single();
    final storagePath =
        (row['verified_photos'] as Map<String, dynamic>)['storage_path'] as String;
    return signedUrl(storagePath);
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

final persistedPhotosProvider = FutureProvider<List<VerifiedPhotoSummary>>((ref) {
  return ref.watch(photoRepositoryProvider).listPersistedPhotos();
});

final verifiedPhotoUrlProvider = FutureProvider.family<String, String>((ref, storagePath) {
  return ref.watch(photoRepositoryProvider).signedUrl(storagePath);
});

final originalPhotoUrlProvider = FutureProvider.family<String, String>((ref, photoSessionId) {
  return ref.watch(photoRepositoryProvider).originalPhotoUrlForSession(photoSessionId);
});
