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
  /// `promptText`, el sub-modo máscara manda `maskBase64` (PNG codificado en
  /// base64) -- ver cada case para el detalle.
  Future<GenerationOutcome> generate({
    required GenerationSource source,
    // photoSessionId es null para los modos que omiten verify-photo
    // (RemoveBackgroundSource, EnhanceQualitySource con foto nueva).
    String? photoSessionId,
    Uint8List? directPhotoBytes,
    String? directContentType,
    String? secondPhotoSessionId,
    Uint8List? maskBytes,
    List<String>? garmentPhotoSessionIds,
    List<String>? garmentIds,
  }) async {
    final String functionName;
    final Map<String, dynamic> body;
    switch (source) {
      case CatalogSource():
        functionName = 'generate-catalog';
        body = {'templateId': source.template.id, 'photoSessionId': photoSessionId};
      case AddElementSource(mode: AddTargetMode.text):
        functionName = 'generate-add-element';
        body = {
          'promptText': source.prompt,
          'photoSessionId': photoSessionId,
          if (secondPhotoSessionId != null) 'secondPhotoSessionId': secondPhotoSessionId,
        };
      case AddElementSource(mode: AddTargetMode.mask):
        // Misma convención que RemoveElementSource(mode: .mask): la máscara
        // se manda como base64 sin prefijo data URI, la Edge Function añade
        // el prefijo antes de llamar a flux-fill-pro.
        functionName = 'generate-add-mask';
        body = {
          'photoSessionId': photoSessionId,
          'maskBase64': base64Encode(maskBytes!),
          'promptText': source.prompt,
        };
      case RemoveElementSource(mode: RemoveTargetMode.text):
        // Máximo 1 foto en este modo (ver PhotoSelectScreen._maxSelectedImages),
        // así que no hay secondPhotoSessionId que mandar.
        functionName = 'generate-remove-element';
        body = {'promptText': source.prompt, 'photoSessionId': photoSessionId};
      case RemoveElementSource(mode: RemoveTargetMode.mask):
        // La máscara viene de MaskPainterScreen como PNG en bytes --
        // se manda como base64 sin prefijo data URI; la Edge Function añade
        // el prefijo antes de llamar a flux-fill-pro. promptText es opcional
        // aquí (pista extra sobre qué debería haber en el fondo).
        functionName = 'generate-remove-mask';
        body = {
          'photoSessionId': photoSessionId,
          'maskBase64': base64Encode(maskBytes!),
          if (source.prompt.isNotEmpty) 'promptText': source.prompt,
        };
      case ModifyElementSource():
        // Misma convención que AddElementSource(mode: .mask): la máscara se
        // manda como base64 sin prefijo data URI, la Edge Function añade el
        // prefijo antes de llamar a flux-fill-pro.
        functionName = 'generate-modify-mask';
        body = {
          'photoSessionId': photoSessionId,
          'maskBase64': base64Encode(maskBytes!),
          'promptText': source.prompt,
        };
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
