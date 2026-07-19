import 'generation_outcome.dart';
import 'generation_source.dart';

/// Payload que Processing pasa a Result (`extra` de go_router). Lleva
/// `photoSessionId` para que "Otra vez" pueda volver a Processing en modo
/// `.fromSession` sin re-verificar la foto.
class ResultArgs {
  const ResultArgs({
    required this.source,
    required this.resultUrl,
    required this.generationId,
    required this.photoSessionId,
    this.creditSource,
  });

  final GenerationSource source;
  final String resultUrl;
  final String generationId;
  final String photoSessionId;
  final GenerationCreditSource? creditSource;
}
