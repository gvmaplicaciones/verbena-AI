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

/// Modo "Añadir algo" (grid de Home, FASE 0). Sin campos propios todavía --
/// se añaden (p.ej. descripción del objeto) cuando se conecte a un backend
/// real en una fase siguiente. Por ahora es un modo "Próximamente", ver
/// GenerationSourceStatus.isComingSoon más abajo.
class AddElementSource extends GenerationSource {
  const AddElementSource();
}

/// Cómo señala el usuario qué eliminar de la foto: descripción en texto o
/// marcando la zona a mano sobre la imagen (máscara).
enum RemoveTargetMode { text, mask }

/// Modo "Eliminar algo" (grid de Home, FASE 0). `mode` ya modela cómo se
/// señalará qué quitar, pero ninguna pantalla lo lee todavía -- se conecta
/// junto con el resto del modo en una fase siguiente.
class RemoveElementSource extends GenerationSource {
  const RemoveElementSource({this.mode = RemoveTargetMode.text});

  final RemoveTargetMode mode;
}

/// Modo "Cambiar fondo" (grid de Home, FASE 0). Sin campos propios todavía.
class ChangeBackgroundSource extends GenerationSource {
  const ChangeBackgroundSource();
}

/// Modo "Probar un look" (grid de Home, FASE 0). Sin campos propios todavía.
class TryOnSource extends GenerationSource {
  const TryOnSource();
}

/// Qué modos ya generan de verdad -- centralizado aquí para que
/// ProcessingScreen (que corta el flujo antes de verify-photo/generate para
/// los modos "Próximamente") y cualquier otro sitio lean la misma fuente de
/// verdad en vez de repetir `is AddElementSource || is ...` sueltos.
extension GenerationSourceStatus on GenerationSource {
  bool get isComingSoon => switch (this) {
        CatalogSource() || LibertadSource() => false,
        AddElementSource() ||
        RemoveElementSource() ||
        ChangeBackgroundSource() ||
        TryOnSource() =>
          true,
      };
}
