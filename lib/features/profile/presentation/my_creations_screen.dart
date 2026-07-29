import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/repositories/generations_repository.dart';
import 'gallery_grids.dart';

/// Pantalla completa de creaciones -- accesible desde "Ver todas" en
/// ProfileScreen cuando hay más de 5 (la vista previa del perfil se recorta
/// a las últimas 5, ver MyCreationsGrid).
class MyCreationsScreen extends ConsumerWidget {
  const MyCreationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final generationsAsync = ref.watch(myGenerationsProvider);
    final count = generationsAsync.valueOrNull?.length;

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
                        Text('Mis creaciones', style: VerbenaText.display(size: 22)),
                      ],
                    ),
                  ),
                  if (count != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Text(
                        '$count creación${count == 1 ? '' : 'es'}',
                        style: VerbenaText.body(size: 14, color: VerbenaColors.textMuted),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                    child: generationsAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (err, st) => Text(
                        'No se pudieron cargar tus creaciones.',
                        style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
                      ),
                      data: (generations) => MyCreationsGrid(generations: generations),
                    ),
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
