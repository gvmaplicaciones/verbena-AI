import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/repositories/photo_repository.dart';
import 'gallery_grids.dart';

/// Pantalla completa de fotos verificadas -- accesible desde "Ver todas" en
/// ProfileScreen cuando hay más de 5 (la vista previa del perfil se recorta
/// a las últimas 5, ver VerifiedPhotosGrid).
class VerifiedPhotosScreen extends ConsumerWidget {
  const VerifiedPhotosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final persistedAsync = ref.watch(persistedPhotosProvider);
    final count = persistedAsync.valueOrNull?.length;

    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
            child: SingleChildScrollView(
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
                        Text('Fotos verificadas', style: VerbenaText.display(size: 22)),
                      ],
                    ),
                  ),
                  if (count != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Text(
                        '$count foto${count == 1 ? '' : 's'}',
                        style: VerbenaText.body(size: 14, color: VerbenaColors.textMuted),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                    child: VerifiedPhotosGrid(persistedAsync: persistedAsync),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
