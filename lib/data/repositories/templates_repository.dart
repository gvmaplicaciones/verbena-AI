import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/template.dart';
import '../providers/supabase_provider.dart';

class TemplatesRepository {
  TemplatesRepository(this._client);

  final SupabaseClient _client;

  Future<List<TemplateCategory>> fetchCategories() async {
    final rows = await _client
        .from('template_categories')
        .select()
        .eq('is_active', true)
        .order('sort_order');
    return rows.map(TemplateCategory.fromJson).toList();
  }

  Future<List<Template>> fetchTemplates(String categoryId) async {
    final rows = await _client
        .from('templates')
        .select()
        .eq('category_id', categoryId)
        .eq('is_active', true)
        .order('sort_order');
    return rows.map(Template.fromJson).toList();
  }
}

final templatesRepositoryProvider = Provider<TemplatesRepository>((ref) {
  return TemplatesRepository(ref.watch(supabaseClientProvider));
});
