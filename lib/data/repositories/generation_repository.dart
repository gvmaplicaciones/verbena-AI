import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/generation_outcome.dart';
import '../models/generation_source.dart';
import '../providers/supabase_provider.dart';

class GenerationRepository {
  GenerationRepository(this._client);

  final SupabaseClient _client;

  /// Llama a generate-catalog/generate-libertad según el origen. El body
  /// varía: Catálogo manda `templateId`, Libertad manda `promptText` (no
  /// `prompt` -- la Edge Function así lo espera).
  Future<GenerationOutcome> generate({
    required GenerationSource source,
    required String photoSessionId,
  }) async {
    final String functionName;
    final Map<String, dynamic> body;
    switch (source) {
      case CatalogSource():
        functionName = 'generate-catalog';
        body = {'templateId': source.template.id, 'photoSessionId': photoSessionId};
      case LibertadSource():
        functionName = 'generate-libertad';
        body = {'promptText': source.prompt, 'photoSessionId': photoSessionId};
    }

    final response = await _client.functions.invoke(functionName, body: body);
    final data = response.data;

    if (response.status == 402) {
      throw InsufficientCreditsException();
    }
    if (response.status != 200) {
      final message = data is Map ? data['error']?.toString() : null;
      throw GenerationException(message ?? '$functionName failed (${response.status})');
    }

    final json = data as Map<String, dynamic>;
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
