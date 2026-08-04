import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/generation_outcome.dart';
import '../models/generation_source.dart';
import '../providers/supabase_provider.dart';

// Necesario para que Replicate acepte la imagen directamente sin pasar por
// verify-photo (modos RemoveBackground y EnhanceQuality).
String _toDataUri(Uint8List bytes, String contentType) =>
    'data:$contentType;base64,${base64Encode(bytes)}';

class GenerationRepository {
  GenerationRepository(this._client);

  final SupabaseClient _client;

  /// Llama a la Edge Function correspondiente según el origen. El body varía
  /// por modo: Catálogo manda `templateId`, modos con prompt mandan
  /// `promptText` -- ver cada case para el detalle.
  Future<GenerationOutcome> generate({
    required GenerationSource source,
    // photoSessionId es null para los modos que omiten verify-photo
    // (RemoveBackgroundSource, EnhanceQualitySource con foto nueva).
    String? photoSessionId,
    Uint8List? directPhotoBytes,
    String? directContentType,
    String? secondPhotoSessionId,
    List<String>? garmentPhotoSessionIds,
    List<String>? garmentIds,
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
      case TryOnSource():
        functionName = 'generate-try-on';
        body = {
          'photoSessionId': photoSessionId,
          if (garmentPhotoSessionIds != null && garmentPhotoSessionIds.isNotEmpty)
            'garmentPhotoSessionIds': garmentPhotoSessionIds,
          if (garmentIds != null && garmentIds.isNotEmpty) 'garmentIds': garmentIds,
        };
      case RemoveBackgroundSource():
        functionName = 'generate-remove-background';
        body = directPhotoBytes != null
            ? {'photoBase64': _toDataUri(directPhotoBytes, directContentType!)}
            : {'photoSessionId': photoSessionId};
      case EnhanceQualitySource():
        functionName = 'generate-enhance-quality';
        body = directPhotoBytes != null
            ? {'photoBase64': _toDataUri(directPhotoBytes, directContentType!)}
            : {'photoSessionId': photoSessionId};
    }

    // invoke() lanza FunctionException para cualquier respuesta no-2xx (402
    // incluido) en vez de devolverla como FunctionResponse normal -- por eso
    // el status se comprueba en el catch, no en response.status.
    // Timeout por encima del presupuesto máximo del pipeline server-side
    // (~180s de Replicate + verificación): si la Edge Function se cuelga, el
    // cliente no puede quedarse esperando indefinidamente en Processing.
    final FunctionResponse response;
    try {
      response = await _client.functions
          .invoke(functionName, body: body)
          .timeout(const Duration(seconds: 240));
    } on FunctionException catch (e) {
      if (e.status == 402) throw InsufficientCreditsException();
      final message = e.details is Map ? (e.details as Map)['error']?.toString() : null;
      throw GenerationException(message ?? '$functionName failed (${e.status})');
    } on TimeoutException {
      throw GenerationException('$functionName timed out after 240s');
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
