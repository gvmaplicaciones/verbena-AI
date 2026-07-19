import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_credits.dart';
import '../providers/supabase_provider.dart';

class CreditsRepository {
  CreditsRepository(this._client);

  final SupabaseClient _client;

  Future<UserCredits> fetchMyCredits() async {
    final userId = _client.auth.currentUser!.id;
    final row = await _client.from('user_credits').select().eq('user_id', userId).single();
    return UserCredits.fromJson(row);
  }

  // El descuento/reset de créditos NUNCA se hace desde el cliente: lo hacen
  // las Edge Functions (generate-catalog, generate-libertad,
  // revenuecat-webhook) con la service role, para que la lógica de negocio
  // (orden tier->extra, no cobrar si falla la verificación, etc.) tenga una
  // única fuente de verdad server-side.
}

final creditsRepositoryProvider = Provider<CreditsRepository>((ref) {
  return CreditsRepository(ref.watch(supabaseClientProvider));
});

final myCreditsProvider = FutureProvider<UserCredits>((ref) {
  return ref.watch(creditsRepositoryProvider).fetchMyCredits();
});
