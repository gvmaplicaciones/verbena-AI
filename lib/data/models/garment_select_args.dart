import 'dart:typed_data';

import 'generation_source.dart';

/// Payload que PhotoSelect pasa a GarmentSelectScreen para TryOnSource, una
/// vez resuelta la foto de la persona: `.fromPhoto` (bytes recién elegidos,
/// GarmentSelectScreen no los verifica, eso lo hace ProcessingScreen) o
/// `.fromSession` (foto ya verificada, sessionId listo).
class GarmentSelectArgs {
  const GarmentSelectArgs.fromPhoto({
    required this.source,
    required Uint8List this.photoBytes,
    required String this.contentType,
  }) : photoSessionId = null;

  const GarmentSelectArgs.fromSession({
    required this.source,
    required String this.photoSessionId,
  })  : photoBytes = null,
        contentType = null;

  final GenerationSource source;
  final Uint8List? photoBytes;
  final String? contentType;
  final String? photoSessionId;
}
