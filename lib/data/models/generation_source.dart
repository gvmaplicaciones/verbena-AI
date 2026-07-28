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

/// Cómo señala el usuario dónde añadir algo en la foto: descripción en texto
/// o marcando la zona a mano sobre la imagen (máscara).
enum AddTargetMode { text, mask }

/// Modo "Añade o modifica algo" (grid de Home, fusión de los antiguos
/// "Añadir algo"/"Modificar algo"). Siempre por texto ahora (generate-add-
/// element) -- el prompt libre del usuario cubre "añadir" y "modificar" por
/// igual sin distinción de código, sin selector de sub-modo previo.
/// `mode: .mask` (generate-add-mask, stable-diffusion-inpainting) queda sin
/// usar en el menú -- deprecated, no borrado, por si se retoma en el futuro
/// con otro modelo de máscara mejor.
class AddElementSource extends GenerationSource {
  const AddElementSource({this.mode = AddTargetMode.text, this.prompt = ''});

  final AddTargetMode mode;
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

/// Antiguo modo "Modificar algo" (5ª ficha de Home) -- fusionado con
/// "Añadir algo" en AddElementSource (ver arriba). Sin ficha propia en Home
/// ya, deprecated, no borrado, por si se retoma en el futuro con otro modelo
/// de máscara mejor (generate-modify-mask, flux-fill-pro).
class ModifyElementSource extends GenerationSource {
  const ModifyElementSource({this.prompt = ''});

  final String prompt;
}

/// Qué modos ya generan de verdad -- centralizado aquí para que
/// ProcessingScreen (que corta el flujo antes de verify-photo/generate para
/// los modos "Próximamente") y cualquier otro sitio lean la misma fuente de
/// verdad en vez de repetir `is AddElementSource || is ...` sueltos.
extension GenerationSourceStatus on GenerationSource {
  bool get isComingSoon => switch (this) {
        CatalogSource() || AddElementSource() => false,
        RemoveElementSource(mode: RemoveTargetMode.text) => false,
        RemoveElementSource(mode: RemoveTargetMode.mask) => false,
        ChangeBackgroundSource() => false,
        ModifyElementSource() => false,
        TryOnSource() => false,
        RemoveBackgroundSource() => false,
        EnhanceQualitySource() => false,
      };
}
