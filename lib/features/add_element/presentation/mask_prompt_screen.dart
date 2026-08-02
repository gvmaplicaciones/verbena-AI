import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/navigation.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/models/mask_prompt_args.dart';
import '../../../data/models/processing_args.dart';

const _addMaskPromptSuggestions = [
  'Un reloj dorado',
  'Un collar de oro',
  'Una gorra roja',
  'Un tatuaje',
];

const _modifyMaskPromptSuggestions = [
  'Que la camiseta sea roja',
  'Cambia el color de pelo a rubio',
  'Que sea de noche en vez de de día',
  'Cambia el color de los ojos',
];

// A diferencia de Añadir/Modificar, aquí el texto es opcional -- la intención
// ya está en lo pintado, esto es solo una pista sobre qué debería haber en el
// fondo en lugar del objeto eliminado (ver MASK_REMOVAL_PROMPT en el backend).
const _removeMaskPromptSuggestions = [
  'Pared lisa',
  'Continúa el suelo',
  'Cielo despejado',
  'Fondo de vegetación',
];

/// Último paso de los sub-modos por máscara que necesitan texto además de lo
/// pintado ("Añadir algo > Con máscara", "Modificar algo" y, opcionalmente,
/// "Eliminar algo"): la máscara ya está pintada (MaskPainterScreen), aquí el
/// usuario describe qué añadir, cómo cambiar la zona marcada, o (solo en
/// Eliminar, opcional) qué debería haber en el fondo en su lugar, antes de
/// construir ProcessingArgs. El tipo de `args.source` (sin prompt aún) decide
/// chips/textos y cómo reconstruir el source final en `_submit`.
class MaskPromptScreen extends StatefulWidget {
  const MaskPromptScreen({super.key, required this.args});

  final MaskPromptArgs args;

  @override
  State<MaskPromptScreen> createState() => _MaskPromptScreenState();
}

class _MaskPromptScreenState extends State<MaskPromptScreen> {
  final _promptController = TextEditingController();

  bool get _isModify => widget.args.source is ModifyElementSource;
  bool get _isRemove => widget.args.source is RemoveElementSource;

  // Eliminar algo: el texto es opcional (pista sobre el fondo), así que
  // siempre se puede generar aunque el campo esté vacío.
  bool get _canSubmit =>
      _isRemove || _promptController.text.trim().isNotEmpty;

  List<String> get _suggestions => switch (widget.args.source) {
        ModifyElementSource() => _modifyMaskPromptSuggestions,
        RemoveElementSource() => _removeMaskPromptSuggestions,
        _ => _addMaskPromptSuggestions,
      };

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  void _submit() {
    final prompt = _promptController.text.trim();
    if (!_canSubmit) return;
    final GenerationSource source = switch (widget.args.source) {
      ModifyElementSource() => ModifyElementSource(prompt: prompt),
      RemoveElementSource() =>
        RemoveElementSource(mode: RemoveTargetMode.mask, prompt: prompt),
      _ => AddElementSource(mode: AddTargetMode.mask, prompt: prompt),
    };

    final ProcessingArgs args;
    if (widget.args.photoSessionId != null) {
      args = ProcessingArgs.fromSession(
        source: source,
        photoSessionId: widget.args.photoSessionId!,
        maskBytes: widget.args.maskBytes,
      );
    } else {
      args = ProcessingArgs.fromPhoto(
        source: source,
        photoBytes: widget.args.photoBytes!,
        contentType: widget.args.contentType!,
        maskBytes: widget.args.maskBytes,
      );
    }
    context.push(AppRoutes.processing, extra: args);
  }

  @override
  Widget build(BuildContext context) {
    final title = _isRemove
        ? 'Describe el fondo (opcional)'
        : _isModify
            ? 'Describe el cambio'
            : 'Describe qué añadir';
    final subtitle = _isRemove
        ? 'Si quieres, dinos qué debería haber en la zona marcada en su lugar'
        : _isModify
            ? 'Cuéntanos cómo quieres que cambie la zona marcada'
            : 'Cuéntanos qué quieres añadir en la zona marcada';
    final hint = _isRemove
        ? 'Opcional... ej: pared lisa, cielo despejado'
        : _isModify
            ? 'Describe el cambio... ej: que la camiseta sea roja'
            : 'Describe qué añadir... ej: un reloj dorado en la muñeca';

    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Row(
                    children: [
                      VerbenaRoundIconButton(
                        icon: const VerbenaBackChevronIcon(),
                        onTap: () => context.safePop(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(title, style: VerbenaText.display(size: 20)),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    subtitle,
                    style: VerbenaText.body(
                        size: 14, color: VerbenaColors.textMuted),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                    children: [
                      SizedBox(
                        height: 36,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _suggestions.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final suggestion = _suggestions[i];
                            return GestureDetector(
                              onTap: () => setState(
                                  () => _promptController.text = suggestion),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: VerbenaColors.card,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                      color: VerbenaColors.textDark
                                          .withValues(alpha: 0.15),
                                      width: 1.5),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  suggestion,
                                  style: VerbenaText.body(
                                      size: 12.5, weight: FontWeight.w500),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _promptController,
                        minLines: 5,
                        maxLines: 8,
                        style: VerbenaText.body(size: 15),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: hint,
                          hintStyle: VerbenaText.body(
                              size: 15, color: VerbenaColors.textMuted),
                          filled: true,
                          fillColor: VerbenaColors.card,
                          contentPadding: const EdgeInsets.all(16),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(
                                color: VerbenaColors.textDark
                                    .withValues(alpha: 0.18),
                                width: 1.5),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(
                                color: VerbenaColors.textDark
                                    .withValues(alpha: 0.18),
                                width: 1.5),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                                color: VerbenaColors.teal, width: 1.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _canSubmit ? _submit : null,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                            textStyle: VerbenaText.display(
                                size: 15,
                                color: VerbenaColors.background,
                                letterSpacing: 0.4),
                          ),
                          child: const Text('GENERAR'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
