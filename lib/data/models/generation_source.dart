import 'template.dart';

/// De dónde viene la generación que el usuario está a punto de pedir —
/// se pasa como `extra` de go_router de Home a PhotoSelect, que necesita
/// saberlo para construir el payload de generate-catalog o generate-libertad.
sealed class GenerationSource {
  const GenerationSource();
}

class CatalogSource extends GenerationSource {
  const CatalogSource(this.template);

  final Template template;
}

class LibertadSource extends GenerationSource {
  const LibertadSource(this.prompt);

  final String prompt;
}
