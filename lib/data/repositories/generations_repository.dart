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
        .select('id, mode, prompt_text, result_storage_path, created_at')
        .eq('user_id', _client.auth.currentUser!.id)
        .eq('status', 'completed')
        .not('result_storage_path', 'is', null)
        .order('created_at', ascending: false);
    return rows.map(GenerationSummary.fromJson).toList();
  }

  Future<String> signedUrl(String storagePath) => _client.storage
      .from('generation-results')
      .createSignedUrl(storagePath, 3600);
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
