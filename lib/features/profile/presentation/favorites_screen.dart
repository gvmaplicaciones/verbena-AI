import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/navigation.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/repositories/generations_repository.dart';
import 'gallery_grids.dart';

/// Pantalla completa de favoritas -- accesible desde "Ver todas" en
/// ProfileScreen. Filtra client-side sobre myGenerationsProvider (máximo 10
/// favoritas, validado server-side en toggle-generation-favorite).
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final generationsAsync = ref.watch(myGenerationsProvider);
    final favoritesAsync = generationsAsync.whenData(
      (generations) => generations.where((g) => g.isFavorite).toList(),
    );
    final count = favoritesAsync.valueOrNull?.length;

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
                          onTap: () => context.safePop(),
                        ),
                        const SizedBox(width: 12),
                        Text('Mis favoritas', style: VerbenaText.display(size: 22)),
                      ],
                    ),
                  ),
                  if (count != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Text(
                        '$count/10 favoritas',
                        style: VerbenaText.body(size: 14, color: VerbenaColors.textMuted),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                    child: favoritesAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (err, st) => Text(
                        'No se pudieron cargar tus favoritas.',
                        style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
                      ),
                      data: (favorites) => MyCreationsGrid(generations: favorites),
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
