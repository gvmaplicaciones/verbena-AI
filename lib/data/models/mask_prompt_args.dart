import 'dart:typed_data';

import 'generation_source.dart';

/// Payload que MaskPainterScreen pasa a MaskPromptScreen cuando el modo
/// necesita texto además de la máscara ("Añadir algo" y "Modificar algo"):
/// la máscara ya está pintada, falta que el usuario describa qué añadir o
/// cómo cambiar la zona marcada antes de construir ProcessingArgs. [source]
/// llega sin `prompt` todavía (AddElementSource(mode: .mask) o
/// ModifyElementSource) -- MaskPromptScreen decide chips/textos según su tipo
/// y reconstruye el source con el prompt final en `_submit`. Dos variantes,
/// igual que MaskPainterArgs/ProcessingArgs: `.fromPhoto` (foto recién
/// elegida) y `.fromSession` (foto ya verificada).
class MaskPromptArgs {
  const MaskPromptArgs.fromPhoto({
    required this.source,
    required Uint8List this.photoBytes,
    required String this.contentType,
    required this.maskBytes,
  }) : photoSessionId = null;

  const MaskPromptArgs.fromSession({
    required this.source,
    required String this.photoSessionId,
    required this.maskBytes,
  })  : photoBytes = null,
        contentType = null;

  final GenerationSource source;
  final Uint8List? photoBytes;
  final String? contentType;
  final String? photoSessionId;
  final Uint8List maskBytes;
}
