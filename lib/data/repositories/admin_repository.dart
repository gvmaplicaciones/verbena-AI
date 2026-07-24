import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/admin_template.dart';
import '../models/template.dart';
import '../providers/supabase_provider.dart';

/// Clave usada tanto aquí como en main.dart (arranque en frío) para
/// encontrar/limpiar el refresh token anónimo guardado al entrar en modo
/// admin.
const savedAnonRefreshTokenPrefsKey = 'admin_saved_anon_refresh_token';

/// Menú de admin oculto dentro de la propia app VerbenAI (gesto secreto en
/// el avatar de Home, ver profile/home_screen.dart) en vez del panel web
/// separado verbena-admin (repo dejado sin desplegar) -- así se pueden crear
/// plantillas desde el móvil sin PC. Usa la misma cuenta de Supabase Auth
/// (email/contraseña) y las mismas políticas RLS de `admin_users` que ese
/// panel y que generate-template-asset.
/// Cómo se construye el prompt final en modo Catálogo (ver runCatalogGeneration
/// en supabase/functions/_shared/replicate.ts): 'aditiva' no añade sufijo de
/// formato (el scene_prompt ya preserva la pose/encuadre del usuario),
/// 'escenaCompleta' añade el sufijo fijo de selfie, 'composicionGrafica' el
/// sufijo contrario (producción profesional cuidada, no selfie casual).
enum TemplateType { aditiva, escenaCompleta, composicionGrafica }

extension on TemplateType {
  String get wireValue => switch (this) {
        TemplateType.aditiva => 'aditiva',
        TemplateType.escenaCompleta => 'escena_completa',
        TemplateType.composicionGrafica => 'composicion_grafica',
      };
}

class AdminRepository {
  AdminRepository(this._client);

  final SupabaseClient _client;

  Future<void> _saveAnonymousSession() async {
    final refreshToken = _client.auth.currentSession?.refreshToken;
    if (refreshToken == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(savedAnonRefreshTokenPrefsKey, refreshToken);
  }

  /// Si las credenciales son válidas pero la cuenta no está en
  /// `admin_users`, deshace el login inmediatamente (restaura la sesión
  /// anónima) en vez de dejar al dispositivo con una sesión real sin
  /// privilegios -- misma verificación que hace generate-template-asset
  /// server-side, repetida aquí porque el resto de pantallas de admin
  /// dependen solo de RLS, sin pasar por ninguna Edge Function.
  Future<void> signInAdmin({required String email, required String password}) async {
    await _saveAnonymousSession();
    await _client.auth.signInWithPassword(email: email, password: password);

    final userId = _client.auth.currentUser?.id;
    final adminRow = userId == null
        ? null
        : await _client.from('admin_users').select('user_id').eq('user_id', userId).maybeSingle();

    if (adminRow == null) {
      await exitAdminMode();
      throw AdminException('Esta cuenta no tiene acceso de admin.');
    }
  }

  /// Restaura la sesión anónima guardada antes de entrar en modo admin, para
  /// que el usuario recupere sus créditos/fotos reales sin conflicto con la
  /// identidad del admin. Si no hay ninguna guardada (p.ej. se llama sin
  /// haber entrado en modo admin), arranca una sesión anónima nueva.
  Future<void> exitAdminMode() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRefreshToken = prefs.getString(savedAnonRefreshTokenPrefsKey);
    await _client.auth.signOut();
    if (savedRefreshToken != null) {
      await _client.auth.setSession(savedRefreshToken);
      await prefs.remove(savedAnonRefreshTokenPrefsKey);
    } else {
      await _client.auth.signInAnonymously();
    }
  }

  Future<List<AdminTemplate>> fetchAllTemplates() async {
    final rows = await _client.from('templates').select().order('category_id').order('sort_order');
    return rows.map(AdminTemplate.fromJson).toList();
  }

  Future<String> signedImageUrl(String storagePath) {
    return _client.storage.from('templates').createSignedUrl(storagePath, 3600);
  }

  Future<void> setActive(String templateId, bool isActive) async {
    await _client.from('templates').update({'is_active': isActive}).eq('id', templateId);
  }

  /// Borra primero la fila y solo si eso funciona el objeto de Storage --
  /// nunca al revés. Si `generations` sigue referenciando la plantilla, el
  /// delete falla por foreign key (ver FLUTTER-7 / _delete en
  /// admin_templates_screen.dart) y con el orden inverso el objeto ya se
  /// habría borrado, dejando una plantilla activa sin imagen (causó el 404
  /// "Object not found" de FLUTTER-8 en generate-catalog).
  Future<void> deleteTemplate(String templateId, String imageStoragePath) async {
    await _client.from('templates').delete().eq('id', templateId);
    await _client.storage.from('templates').remove([imageStoragePath]);
  }

  /// A diferencia de fetchCategories() en TemplatesRepository (solo activas,
  /// para el dropdown público), aquí trae también las desactivadas para que
  /// el admin pueda reactivarlas.
  Future<List<TemplateCategory>> fetchAllCategories() async {
    final rows = await _client.from('template_categories').select().order('sort_order');
    return rows.map(TemplateCategory.fromJson).toList();
  }

  /// `id` es el slug (primary key en texto, p.ej. 'gamberro'), no un uuid.
  Future<void> createCategory({
    required String id,
    required String label,
    String? badgeText,
    int sortOrder = 0,
  }) async {
    await _client.from('template_categories').insert({
      'id': id,
      'label': label,
      'badge_text': badgeText,
      'sort_order': sortOrder,
    });
  }

  Future<void> setCategoryActive(String categoryId, bool isActive) async {
    await _client.from('template_categories').update({'is_active': isActive}).eq('id', categoryId);
  }

  /// Puede fallar con una foreign key violation si aún hay plantillas
  /// usando esta categoría (templates.category_id no tiene ON DELETE) --
  /// el caller debe capturarlo y avisar al admin en vez de dejarlo reventar.
  Future<void> deleteCategory(String categoryId) async {
    await _client.from('template_categories').delete().eq('id', categoryId);
  }

  /// Misma Edge Function que usa verbena-admin: genera la MINIATURA (solo
  /// decorativa, grid de Home) a partir de `prompt`, la sube y crea la fila
  /// con is_active=false para revisar antes de publicar (ver
  /// generate-template-asset/index.ts). `scenePrompt`/`templateType` son la
  /// instrucción real de generación en modo Catálogo, no la miniatura.
  Future<GeneratedTemplatePreview> generateTemplate({
    required String categoryId,
    required String name,
    required String prompt,
    required String scenePrompt,
    required TemplateType templateType,
    String? objectReferenceImagePath,
    String replicateModel = 'flux-1.1-pro',
    int sortOrder = 0,
  }) async {
    final response = await _client.functions.invoke('generate-template-asset', body: {
      'categoryId': categoryId,
      'name': name,
      'prompt': prompt,
      'scenePrompt': scenePrompt,
      'templateType': templateType.wireValue,
      'objectReferenceImagePath': objectReferenceImagePath,
      'replicateModel': replicateModel,
      'sortOrder': sortOrder,
    });
    final data = response.data;
    if (response.status != 200) {
      final message = data is Map ? data['error']?.toString() : null;
      throw AdminException(message ?? 'generate-template-asset failed (${response.status})');
    }
    final json = data as Map<String, dynamic>;
    return GeneratedTemplatePreview(
      templateId: json['templateId'] as String,
      imageStoragePath: json['imageStoragePath'] as String,
      previewUrl: json['previewUrl'] as String,
    );
  }

  /// Alternativa a [generateTemplate]: sube una imagen elegida por el admin
  /// tal cual, sin pasar por generate-template-asset ni Replicate. Mismo
  /// resultado (fila is_active=false para revisar antes de publicar) y
  /// mismo bucket privado 'templates' -- la política RLS "admin manages
  /// templates storage" permite este insert directo desde el cliente sin
  /// necesitar una Edge Function. `replicate_model` se marca 'upload' para
  /// distinguir el origen (ver migración 20260722000000).
  Future<GeneratedTemplatePreview> uploadTemplateImage({
    required String categoryId,
    required String name,
    required String scenePrompt,
    required TemplateType templateType,
    String? objectReferenceImagePath,
    required Uint8List bytes,
    required String contentType,
    int sortOrder = 0,
  }) async {
    final imageStoragePath = '$categoryId/${_randomFileToken()}.${_extensionFor(contentType)}';
    await _client.storage.from('templates').uploadBinary(
          imageStoragePath,
          bytes,
          fileOptions: FileOptions(contentType: contentType),
        );

    final template = await _client
        .from('templates')
        .insert({
          'category_id': categoryId,
          'name': name,
          'image_storage_path': imageStoragePath,
          'scene_prompt': scenePrompt,
          'template_type': templateType.wireValue,
          'object_reference_image': objectReferenceImagePath,
          'replicate_model': 'upload',
          'is_active': false,
          'sort_order': sortOrder,
        })
        .select('id')
        .single();

    final previewUrl = await signedImageUrl(imageStoragePath);
    return GeneratedTemplatePreview(
      templateId: template['id'] as String,
      imageStoragePath: imageStoragePath,
      previewUrl: previewUrl,
    );
  }

  /// Sube la imagen opcional de referencia de objeto (ej. un collar) que se
  /// incorpora como segunda imagen de referencia junto a la foto del usuario
  /// en modo Catálogo -- mismo bucket privado 'templates', subcarpeta 'refs'
  /// para no mezclarla con las miniaturas. El propio scene_prompt de la
  /// plantilla es quien la referencia en texto, no hay sufijo fijo para esto.
  Future<String> uploadObjectReferenceImage({
    required String categoryId,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final path = '$categoryId/refs/${_randomFileToken()}.${_extensionFor(contentType)}';
    await _client.storage.from('templates').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType),
        );
    return path;
  }

  String _extensionFor(String contentType) {
    switch (contentType) {
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
      default:
        return 'jpg';
    }
  }

  String _randomFileToken() {
    final rand = Random.secure();
    final bytes = List.generate(8, (_) => rand.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${DateTime.now().millisecondsSinceEpoch}_$hex';
  }
}

class AdminException implements Exception {
  AdminException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GeneratedTemplatePreview {
  const GeneratedTemplatePreview({
    required this.templateId,
    required this.imageStoragePath,
    required this.previewUrl,
  });
  final String templateId;
  final String imageStoragePath;
  final String previewUrl;
}

final adminRepositoryProvider = Provider<AdminRepository>((ref) {
  return AdminRepository(ref.watch(supabaseClientProvider));
});
