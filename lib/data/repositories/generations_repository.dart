import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/generation_summary.dart';
import '../providers/supabase_provider.dart';

class GenerationsRepository {
  const GenerationsRepository(this._client);

  final SupabaseClient _client;

  Future<List<GenerationSummary>> listMyGenerations() async {
    final rows = await _client
        .from('generations')
        .select('id, mode, prompt_text, result_storage_path, created_at, is_favorite')
        .eq('user_id', _client.auth.currentUser!.id)
        .eq('status', 'completed')
        .not('result_storage_path', 'is', null)
        .order('created_at', ascending: false);
    return rows.map(GenerationSummary.fromJson).toList();
  }

  Future<String> signedUrl(String storagePath) => _client.storage
      .from('generation-results')
      .createSignedUrl(storagePath, 3600);

  Future<void> toggleFavorite(String generationId, bool isFavorite) async {
    try {
      await _client.functions.invoke(
        'toggle-generation-favorite',
        body: {'generationId': generationId, 'isFavorite': isFavorite},
      );
    } on FunctionException catch (e) {
      if (e.status == 409) throw FavoriteLimitException();
      throw GenerationsException('toggle-generation-favorite failed (${e.status})');
    }
  }

  Future<void> deleteGeneration(String generationId) async {
    try {
      await _client.functions.invoke(
        'delete-generation',
        body: {'generationId': generationId},
      );
    } on FunctionException catch (e) {
      throw GenerationsException('delete-generation failed (${e.status})');
    }
  }

  /// Devuelve true si hay ≥30 generaciones no-favoritas con created_at más
  /// reciente que [generationCreatedAt]. Se usa para avisar al usuario antes
  /// de desmarcar una favorita — si cae fuera del top-30 el cron la borrará.
  Future<bool> hasThirtyOrMoreNonFavoritesNewerThan(
    String generationId,
    DateTime generationCreatedAt,
  ) async {
    final rows = await _client
        .from('generations')
        .select('id')
        .eq('user_id', _client.auth.currentUser!.id)
        .eq('status', 'completed')
        .not('result_storage_path', 'is', null)
        .eq('is_favorite', false)
        .gt('created_at', generationCreatedAt.toUtc().toIso8601String())
        .limit(30);
    return rows.length >= 30;
  }
}

class FavoriteLimitException implements Exception {
  @override
  String toString() => 'favorite_limit';
}

class GenerationsException implements Exception {
  GenerationsException(this.message);
  final String message;
  @override
  String toString() => message;
}

final generationsRepositoryProvider = Provider<GenerationsRepository>((ref) {
  return GenerationsRepository(ref.watch(supabaseClientProvider));
});

final myGenerationsProvider = FutureProvider<List<GenerationSummary>>((ref) {
  return ref.watch(generationsRepositoryProvider).listMyGenerations();
});

final generationResultUrlProvider =
    FutureProvider.family<String, String>((ref, storagePath) {
  return ref.watch(generationsRepositoryProvider).signedUrl(storagePath);
});
