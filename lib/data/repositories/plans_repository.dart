import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/plan.dart';
import '../providers/supabase_provider.dart';

class PlansRepository {
  PlansRepository(this._client);

  final SupabaseClient _client;

  Future<List<Plan>> fetchPlans() async {
    final rows = await _client.from('plans').select().eq('is_active', true).order('tier_credits');
    return rows.map(Plan.fromJson).toList();
  }

  Future<List<ExtraPack>> fetchExtraPacks() async {
    final rows = await _client.from('extra_packs').select().eq('is_active', true);
    return rows.map(ExtraPack.fromJson).toList();
  }
}

final plansRepositoryProvider = Provider<PlansRepository>((ref) {
  return PlansRepository(ref.watch(supabaseClientProvider));
});

final plansProvider = FutureProvider<List<Plan>>((ref) {
  return ref.watch(plansRepositoryProvider).fetchPlans();
});

final extraPacksProvider = FutureProvider<List<ExtraPack>>((ref) {
  return ref.watch(plansRepositoryProvider).fetchExtraPacks();
});
