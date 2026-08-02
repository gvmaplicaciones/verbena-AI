import 'dart:typed_data';

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
    this.photoSessionId,
    this.beforeBytes,
    this.creditSource,
  });

  final GenerationSource source;
  final String resultUrl;
  final String generationId;
  // Null para modos que omiten verify-photo (RemoveBackground, EnhanceQuality
  // con foto nueva) -- en ese caso "Otra vez" vuelve a selección de foto.
  final String? photoSessionId;
  // Foto original en memoria, solo cuando `photoSessionId` es null porque el
  // modo se saltó verify-photo (RemoveBackground, EnhanceQuality con foto
  // nueva) -- nunca se sube a Storage, así que es la única forma de mostrar
  // el slider antes/después en ResultScreen para ese caso.
  final Uint8List? beforeBytes;
  final GenerationCreditSource? creditSource;
}
