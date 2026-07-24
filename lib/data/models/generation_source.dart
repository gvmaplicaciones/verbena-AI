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

/// Modo "Añadir algo" (grid de Home). FASE 1: conectado a generación real
/// (generate-add-element) -- describe qué objeto/prenda/accesorio añadir a
/// la foto, igual que el prompt libre que tenía el extinto modo Libertad.
class AddElementSource extends GenerationSource {
  const AddElementSource(this.prompt);

  final String prompt;
}

/// Cómo señala el usuario qué eliminar de la foto: descripción en texto o
/// marcando la zona a mano sobre la imagen (máscara).
enum RemoveTargetMode { text, mask }

/// Modo "Eliminar algo" (grid de Home). FASE 2a: sub-modo "Por texto"
/// conectado a generación real (generate-remove-element) -- describe qué
/// quitar de la foto. `mode: .mask` ("Selecciona lo que quieres borrar")
/// sigue sin implementar, ver RemoveModeSelectScreen.
class RemoveElementSource extends GenerationSource {
  const RemoveElementSource({this.mode = RemoveTargetMode.text, this.prompt = ''});

  final RemoveTargetMode mode;
  final String prompt;
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
        CatalogSource() || AddElementSource() => false,
        RemoveElementSource(mode: RemoveTargetMode.text) => false,
        RemoveElementSource(mode: RemoveTargetMode.mask) => true,
        ChangeBackgroundSource() || TryOnSource() => true,
      };
}
