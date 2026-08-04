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

/// Modo "Añade o modifica algo" (grid de Home, fusión de los antiguos
/// "Añadir algo"/"Modificar algo"). Siempre por texto (generate-add-element)
/// -- el prompt libre del usuario cubre "añadir" y "modificar" por igual sin
/// distinción de código.
class AddElementSource extends GenerationSource {
  const AddElementSource({this.prompt = ''});

  final String prompt;
}

/// Modo "Eliminar algo" (grid de Home). Siempre por texto (generate-remove-
/// element) -- describe qué quitar de la foto.
class RemoveElementSource extends GenerationSource {
  const RemoveElementSource({this.prompt = ''});

  final String prompt;
}

/// Modo "Cambiar fondo" (grid de Home). FASE 3: conectado a generación real
/// (generate-change-background, bytedance/seedream-4.5) -- [placeText]
/// describe el lugar de destino. La foto de referencia del fondo (opcional)
/// viaja aparte, como segunda foto (mismo mecanismo que la segunda foto de
/// AddElementSource, ver ProcessingArgs/PhotoSelectScreen). [placeText] solo
/// es obligatorio cuando no hay foto de referencia; con foto de referencia
/// es un matiz opcional.
class ChangeBackgroundSource extends GenerationSource {
  const ChangeBackgroundSource({this.placeText = ''});

  final String placeText;
}

/// Modo "Probar un look" (grid de Home, FASE 5: prunaai/p-image-try-on). Sin
/// campos propios -- la persona viaja como el resto de modos
/// (photoBytes/photoSessionId) y las prendas (1-4) viajan aparte en
/// ProcessingArgs.garmentPicks, igual que el patrón ya usado para la segunda
/// foto de ChangeBackgroundSource/AddElementSource.
class TryOnSource extends GenerationSource {
  const TryOnSource();
}

/// Modo "Eliminar fondo" (grid de Home, bria/remove-background). Sin campos
/// propios ni texto/máscara -- flujo simplificado: seleccionar foto y generar
/// directo, sin ninguna instrucción del usuario. El resultado preserva el
/// canal alfa y se guarda/comparte como PNG (ver generate-remove-background),
/// a diferencia del resto de modos.
class RemoveBackgroundSource extends GenerationSource {
  const RemoveBackgroundSource();
}

/// Modo "Mejorar calidad" (grid de Home, tencentarc/gfpgan). Sin campos
/// propios -- flujo simplificado igual que RemoveBackgroundSource: seleccionar
/// foto y generar directo, sin instrucción del usuario. Salida JPEG normal
/// (sin canal alfa), misma ruta de guardado/compartido que el resto de modos.
class EnhanceQualitySource extends GenerationSource {
  const EnhanceQualitySource();
}

/// Qué modos ya generan de verdad -- centralizado aquí para que
/// ProcessingScreen (que corta el flujo antes de verify-photo/generate para
/// los modos "Próximamente") y cualquier otro sitio lean la misma fuente de
/// verdad en vez de repetir `is AddElementSource || is ...` sueltos.
extension GenerationSourceStatus on GenerationSource {
  bool get isComingSoon => switch (this) {
        CatalogSource() || AddElementSource() => false,
        RemoveElementSource() => false,
        ChangeBackgroundSource() => false,
        TryOnSource() => false,
        RemoveBackgroundSource() => false,
        EnhanceQualitySource() => false,
      };
}
