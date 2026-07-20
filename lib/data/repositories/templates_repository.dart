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

  /// `categoryId` null trae todas las plantillas activas (opción "TODOS").
  Future<List<Template>> fetchTemplates(String? categoryId) async {
    final builder = _client.from('templates').select().eq('is_active', true);
    final rows = await (categoryId != null ? builder.eq('category_id', categoryId) : builder)
        .order('sort_order');
    return rows.map(Template.fromJson).toList();
  }

  /// El bucket `templates` no es público a nivel de bucket (solo vía RLS
  /// policy de SELECT) -- hace falta URL firmada, `getPublicUrl()` no sirve.
  Future<String> signedImageUrl(String storagePath) async {
    return _client.storage.from('templates').createSignedUrl(storagePath, 3600);
  }
}

final templatesRepositoryProvider = Provider<TemplatesRepository>((ref) {
  return TemplatesRepository(ref.watch(supabaseClientProvider));
});

final templateCategoriesProvider = FutureProvider<List<TemplateCategory>>((ref) {
  return ref.watch(templatesRepositoryProvider).fetchCategories();
});

final templatesByCategoryProvider =
    FutureProvider.family<List<Template>, String?>((ref, categoryId) {
  return ref.watch(templatesRepositoryProvider).fetchTemplates(categoryId);
});

final templateImageUrlProvider = FutureProvider.family<String, String>((ref, storagePath) {
  return ref.watch(templatesRepositoryProvider).signedImageUrl(storagePath);
});
