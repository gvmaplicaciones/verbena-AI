import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/generation_source.dart';

class _SubModeInfo {
  const _SubModeInfo({
    required this.title,
    required this.description,
    required this.imagePath,
  });

  final String title;
  final String description;
  final String imagePath;
}

// Mismo patrón de nombres que assets/modes/ (Fase 0, ver _modes en
// home_screen.dart): snake_case + .jpeg, carpeta única sin subcarpetas.
const _subModes = [
  _SubModeInfo(
    title: 'Por texto',
    description: 'Describe qué quieres eliminar de tu foto',
    imagePath: 'assets/modes/remove_by_text.jpeg',
  ),
  _SubModeInfo(
    title: 'Selecciona lo que quieres borrar',
    description: 'Marca la zona a eliminar directamente sobre la foto',
    imagePath: 'assets/modes/remove_by_mask.jpeg',
  ),
];

/// Paso previo del modo "Eliminar algo" (grid de Home): el usuario elige
/// cómo señala qué quitar de la foto -- por texto (generate-remove-element)
/// o marcando la zona a mano (generate-remove-mask, flux-fill-pro, FASE 4).
/// Mismo patrón visual de fichas grandes que _ModeGrid en home_screen.dart,
/// con imágenes cuadradas (1:1) en vez de las 190px fijas de Home.
class RemoveModeSelectScreen extends StatelessWidget {
  const RemoveModeSelectScreen({super.key});

  void _onTap(BuildContext context, _SubModeInfo mode) {
    final source = mode == _subModes[0]
        ? const RemoveElementSource(mode: RemoveTargetMode.text)
        : const RemoveElementSource(mode: RemoveTargetMode.mask);
    context.push(AppRoutes.photoSelect, extra: source);
  }

  @override
  Widget build(BuildContext context) {
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
                        onTap: () => context.pop(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('Eliminar algo',
                            style: VerbenaText.display(size: 20)),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    '¿Cómo quieres señalar qué eliminar?',
                    style: VerbenaText.body(
                        size: 14, color: VerbenaColors.textMuted),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                    children: [
                      for (final mode in _subModes) ...[
                        _SubModeCard(
                          mode: mode,
                          onTap: () => _onTap(context, mode),
                        ),
                        if (mode != _subModes.last) const SizedBox(height: 16),
                      ],
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

/// Misma ficha visual que _ModeCard en home_screen.dart (imagen + título +
/// descripción), pero con imagen cuadrada (1:1) en vez de los 190px de Home.
class _SubModeCard extends StatelessWidget {
  const _SubModeCard({required this.mode, required this.onTap});

  final _SubModeInfo mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: VerbenaColors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: VerbenaColors.textDark.withValues(alpha: 0.12),
              width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Image.asset(mode.imagePath, fit: BoxFit.cover),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mode.title,
                      style: VerbenaText.body(size: 17, weight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    mode.description,
                    style: VerbenaText.body(
                            size: 13, color: VerbenaColors.textMuted)
                        .copyWith(height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
