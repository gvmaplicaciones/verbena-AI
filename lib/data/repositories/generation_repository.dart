import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/generation_outcome.dart';
import '../models/generation_source.dart';
import '../providers/supabase_provider.dart';

class GenerationRepository {
  GenerationRepository(this._client);

  final SupabaseClient _client;

  /// Llama a generate-catalog/generate-add-element según el origen. El body
  /// varía: Catálogo manda `templateId`, Añadir algo manda `promptText` (no
  /// `prompt` -- la Edge Function así lo espera) y, si hay segunda foto de
  /// referencia, `secondPhotoSessionId` -- Catálogo no admite segunda foto.
  Future<GenerationOutcome> generate({
    required GenerationSource source,
    required String photoSessionId,
    String? secondPhotoSessionId,
  }) async {
    final String functionName;
    final Map<String, dynamic> body;
    switch (source) {
      case CatalogSource():
        functionName = 'generate-catalog';
        body = {'templateId': source.template.id, 'photoSessionId': photoSessionId};
      case AddElementSource():
        functionName = 'generate-add-element';
        body = {
          'promptText': source.prompt,
          'photoSessionId': photoSessionId,
          if (secondPhotoSessionId != null) 'secondPhotoSessionId': secondPhotoSessionId,
        };
      case RemoveElementSource():
        // Máximo 1 foto en este modo (ver PhotoSelectScreen._maxSelectedImages),
        // así que no hay secondPhotoSessionId que mandar.
        functionName = 'generate-remove-element';
        body = {'promptText': source.prompt, 'photoSessionId': photoSessionId};
      case ChangeBackgroundSource():
        // secondPhotoSessionId es la foto de referencia del fondo, opcional
        // -- placeText solo es obligatorio si no hay foto de referencia (ver
        // ChangeBackgroundSource, validado ya en PhotoSelectScreen antes de
        // llegar aquí).
        functionName = 'generate-change-background';
        body = {
          'placeText': source.placeText,
          'photoSessionId': photoSessionId,
          if (secondPhotoSessionId != null) 'secondPhotoSessionId': secondPhotoSessionId,
        };
      // FASE 0 del grid de 4 modos: este source aún no tiene backend --
      // ProcessingScreen corta el flujo antes de llegar aquí (ver
      // GenerationSourceStatus.isComingSoon), así que esta rama es
      // inalcanzable en la práctica. Solo existe para que el switch
      // exhaustivo compile.
      case TryOnSource():
        throw UnimplementedError('$source todavía no está conectado a un backend real');
    }

    // invoke() lanza FunctionException para cualquier respuesta no-2xx (402
    // incluido) en vez de devolverla como FunctionResponse normal -- por eso
    // el status se comprueba en el catch, no en response.status.
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(functionName, body: body);
    } on FunctionException catch (e) {
      if (e.status == 402) throw InsufficientCreditsException();
      final message = e.details is Map ? (e.details as Map)['error']?.toString() : null;
      throw GenerationException(message ?? '$functionName failed (${e.status})');
    }

    final json = response.data as Map<String, dynamic>;
    final outcome = GenerationOutcome.fromJson(json);
    if (!outcome.isCompleted) return outcome;

    // El credit_source (tier/extra/free) no viene en la respuesta de la Edge
    // Function -- se guarda server-side en generations.credit_source y es
    // legible por el cliente vía RLS, así que se lee con una query aparte en
    // vez de tocar la función ya desplegada.
    final row = await _client
        .from('generations')
        .select('credit_source')
        .eq('id', outcome.generationId)
        .single();
    return GenerationOutcome.fromJson(json, creditSource: row['credit_source'] as String?);
  }
}

class GenerationException implements Exception {
  GenerationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class InsufficientCreditsException implements Exception {
  @override
  String toString() => 'insufficient_credits';
}

final generationRepositoryProvider = Provider<GenerationRepository>((ref) {
  return GenerationRepository(ref.watch(supabaseClientProvider));
});
