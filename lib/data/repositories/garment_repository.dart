import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/garment.dart';
import '../providers/supabase_provider.dart';

const _contentTypeByExtension = {
  'jpg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
};

/// Repositorio del Armario (FASE 5, solo socios) -- sube/lista/borra prendas
/// vía las Edge Functions dedicadas (upload-garment/delete-garment), mismo
/// patrón que PhotoRepository para fotos verificadas.
class GarmentRepository {
  GarmentRepository(this._client);

  final SupabaseClient _client;

  Future<List<Garment>> listGarments() async {
    final userId = _client.auth.currentUser!.id;
    final rows = await _client
        .from('garments')
        .select('id, storage_path, created_at')
        .eq('user_id', userId)
        .order('created_at', ascending: false);
    return rows.map(Garment.fromJson).toList();
  }

  /// Sube una prenda nueva al Armario. Pasa por moderación server-side --
  /// si se rechaza, lanza [GarmentRejectedException] y no ocupa hueco.
  Future<Garment> uploadGarment({
    required Uint8List bytes,
    required String contentType,
  }) async {
    final response = await _client.functions.invoke(
      'upload-garment',
      body: bytes,
      headers: {'Content-Type': contentType},
    );

    if (response.status == 422) {
      final data = response.data;
      final reason = data is Map ? data['reason']?.toString() : null;
      throw GarmentRejectedException(reason ?? 'La prenda no ha pasado la verificación.');
    }
    if (response.status != 201) {
      final data = response.data;
      final message = data is Map ? data['error']?.toString() : null;
      throw GarmentException(message ?? 'upload-garment failed (${response.status})');
    }

    final data = response.data as Map<String, dynamic>;
    return Garment(
      id: data['id'] as String,
      storagePath: data['storagePath'] as String?,
      createdAt: DateTime.now(),
    );
  }

  Future<void> deleteGarment(String garmentId) async {
    final response = await _client.functions.invoke(
      'delete-garment',
      body: {'garmentId': garmentId},
    );

    if (response.status != 200) {
      final data = response.data;
      final message = data is Map ? data['error']?.toString() : null;
      throw GarmentException(message ?? 'delete-garment failed (${response.status})');
    }
  }

  String contentTypeForPath(String storagePath) {
    final ext = storagePath.split('.').last.toLowerCase();
    return _contentTypeByExtension[ext] ?? 'image/jpeg';
  }

  Future<String> signedUrl(String storagePath) {
    return _client.storage.from('garments').createSignedUrl(storagePath, 3600);
  }
}

class GarmentException implements Exception {
  GarmentException(this.message);
  final String message;

  @override
  String toString() => message;
}

class GarmentRejectedException implements Exception {
  GarmentRejectedException(this.message);
  final String message;

  @override
  String toString() => message;
}

final garmentRepositoryProvider = Provider<GarmentRepository>((ref) {
  return GarmentRepository(ref.watch(supabaseClientProvider));
});

final garmentsProvider = FutureProvider<List<Garment>>((ref) {
  return ref.watch(garmentRepositoryProvider).listGarments();
});

final garmentUrlProvider = FutureProvider.family<String, String>((ref, storagePath) {
  return ref.watch(garmentRepositoryProvider).signedUrl(storagePath);
});
