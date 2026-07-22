import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/credits.dart';
import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/models/template.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/templates_repository.dart';

/// El handoff traía "esta semana" fijo en la tarjeta de créditos aunque el
/// plan activo fuera mensual -- bug de contenido, no de diseño. La cadencia
/// depende del plan real (semanal/mensual); sin plan activo no se muestra
/// nada, no hay periodo que anunciar.
String? _cadenceLabel(String? activePlanId) {
  switch (activePlanId) {
    case PlanIds.semanal:
      return 'esta semana';
    case PlanIds.mensual:
      return 'este mes';
    default:
      return null;
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;
  String? _selectedCategoryId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _HomeHeader(),
              const _CreditsCard(),
              _HomeTabs(
                active: _tab,
                onChanged: (i) => setState(() => _tab = i),
              ),
              if (_tab == 0)
                _CatalogTab(
                  selectedCategoryId: _selectedCategoryId,
                  onCategorySelected: (id) => setState(() => _selectedCategoryId = id),
                )
              else
                const _LibertadTab(),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeHeader extends StatefulWidget {
  const _HomeHeader();

  @override
  State<_HomeHeader> createState() => _HomeHeaderState();
}

class _HomeHeaderState extends State<_HomeHeader> {
  int _avatarLongPressCount = 0;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  /// Gesto oculto sin ningún botón visible: 5 pulsaciones largas seguidas
  /// sobre el avatar (contador reiniciado tras 2s de inactividad) abren el
  /// login del menú de admin -- ver AppRoutes.adminLogin y
  /// data/repositories/admin_repository.dart.
  void _onAvatarLongPress() {
    _resetTimer?.cancel();
    _avatarLongPressCount++;
    if (_avatarLongPressCount >= 5) {
      _avatarLongPressCount = 0;
      context.push(AppRoutes.adminLogin);
      return;
    }
    _resetTimer = Timer(const Duration(seconds: 2), () => _avatarLongPressCount = 0);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('VERBENA', style: VerbenaText.display(size: 24)),
          GestureDetector(
            onTap: () => context.push(AppRoutes.profile),
            onLongPress: _onAvatarLongPress,
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(color: VerbenaColors.teal, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const VerbenaPersonIcon(size: 17),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreditsCard extends ConsumerWidget {
  const _CreditsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creditsAsync = ref.watch(myCreditsProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: creditsAsync.when(
        loading: () => const SizedBox(height: 78),
        error: (err, st) => const SizedBox.shrink(),
        data: (credits) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: VerbenaColors.teal,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CRÉDITOS DE TU PLAN',
                      style: VerbenaText.body(
                        size: 11,
                        color: VerbenaColors.background.withValues(alpha: 0.8),
                        weight: FontWeight.w500,
                      ).copyWith(letterSpacing: 0.5),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '${credits.tierUsed}/${credits.tierTotal}',
                          style: VerbenaText.display(size: 24, color: VerbenaColors.background),
                        ),
                        if (_cadenceLabel(credits.activePlanId) case final label?) ...[
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: VerbenaText.body(
                              size: 13,
                              color: VerbenaColors.background.withValues(alpha: 0.85),
                              weight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (credits.extraCredits > 0)
                Positioned(
                  top: -10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: VerbenaColors.terracotta,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: VerbenaColors.background, width: 2),
                    ),
                    child: Text(
                      '+${credits.extraCredits} extra',
                      style: VerbenaText.body(
                        size: 11.5,
                        color: VerbenaColors.background,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _HomeTabs extends StatelessWidget {
  const _HomeTabs({required this.active, required this.onChanged});

  final int active;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: VerbenaColors.textDark.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(child: _TabButton(label: 'Catálogo', active: active == 0, onTap: () => onChanged(0))),
            const SizedBox(width: 10),
            Expanded(child: _TabButton(label: 'Libertad', active: active == 1, onTap: () => onChanged(1))),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: active ? VerbenaColors.teal : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        alignment: Alignment.center,
        child: Text(
          label.toUpperCase(),
          style: VerbenaText.display(
            size: 14,
            color: active ? VerbenaColors.background : VerbenaColors.textDark,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

class _CatalogTab extends ConsumerWidget {
  const _CatalogTab({
    required this.selectedCategoryId,
    required this.onCategorySelected,
  });

  final String? selectedCategoryId;
  final ValueChanged<String?> onCategorySelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoriesAsync = ref.watch(templateCategoriesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
          child: categoriesAsync.when(
            loading: () => const SizedBox(height: 48),
            error: (err, st) => Text('No se pudieron cargar las categorías.', style: VerbenaText.body()),
            data: (categories) => _CategoryDropdown(
              categories: categories,
              selectedCategoryId: selectedCategoryId,
              onChanged: onCategorySelected,
            ),
          ),
        ),
        _TemplatesGrid(categoryId: selectedCategoryId),
      ],
    );
  }
}

/// Selector desplegable con "TODOS" (value null) por delante de las
/// categorías reales -- antes la fila de chips no dejaba claro qué
/// categorías existían ni había forma de ver todas las plantillas a la vez.
class _CategoryDropdown extends StatelessWidget {
  const _CategoryDropdown({
    required this.categories,
    required this.selectedCategoryId,
    required this.onChanged,
  });

  final List<TemplateCategory> categories;
  final String? selectedCategoryId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: VerbenaColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.15), width: 1.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: selectedCategoryId,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: VerbenaColors.textDark),
          borderRadius: BorderRadius.circular(14),
          dropdownColor: VerbenaColors.card,
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(
                'TODOS',
                style: VerbenaText.body(size: 14.5, weight: FontWeight.w700, color: VerbenaColors.textDark),
              ),
            ),
            ...categories.map(
              (category) => DropdownMenuItem<String?>(
                value: category.id,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      category.label,
                      style: VerbenaText.body(size: 14.5, weight: FontWeight.w600, color: VerbenaColors.textDark),
                    ),
                    if (category.badgeText != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: VerbenaColors.terracotta,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          category.badgeText!,
                          style: VerbenaText.body(size: 9.5, weight: FontWeight.w700, color: VerbenaColors.background),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _TemplatesGrid extends ConsumerWidget {
  const _TemplatesGrid({required this.categoryId});

  final String? categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templatesAsync = ref.watch(templatesByCategoryProvider(categoryId));

    return templatesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (err, st) => Padding(
        padding: const EdgeInsets.all(20),
        child: Text('No se pudieron cargar las plantillas.', style: VerbenaText.body()),
      ),
      data: (templates) {
        if (templates.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text('No hay plantillas en esta categoría.', style: VerbenaText.body()),
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final columnWidth = (constraints.maxWidth - 40 - 14) / 2;
            const estimatedRowHeight = 130 + 6 + 34;
            final aspectRatio = columnWidth / estimatedRowHeight;
            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: aspectRatio,
              ),
              itemCount: templates.length,
              itemBuilder: (context, i) => _TemplateCard(template: templates[i]),
            );
          },
        );
      },
    );
  }
}

class _TemplateCard extends ConsumerWidget {
  const _TemplateCard({required this.template});

  final Template template;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final urlAsync = ref.watch(templateImageUrlProvider(template.imageStoragePath));
    return GestureDetector(
      onTap: () => context.push(AppRoutes.photoSelect, extra: CatalogSource(template)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 130,
              width: double.infinity,
              child: urlAsync.when(
                loading: () => Container(color: VerbenaColors.card),
                error: (err, st) => Container(color: VerbenaColors.card),
                data: (url) => CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Container(color: VerbenaColors.card),
                  errorWidget: (context, url, error) => Container(color: VerbenaColors.card),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            template.name,
            style: VerbenaText.body(size: 13, weight: FontWeight.w600).copyWith(height: 1.25),
          ),
        ],
      ),
    );
  }
}

class _LibertadTab extends StatelessWidget {
  const _LibertadTab();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: VerbenaColors.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.12), width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Describe lo que quieres', style: VerbenaText.display(size: 17)),
                const SizedBox(height: 8),
                Text(
                  'Primero elige una foto y luego nos cuentas qué quieres que hagamos con ella.',
                  style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => context.push(AppRoutes.photoSelect, extra: const LibertadSource('')),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: VerbenaText.display(size: 15, color: VerbenaColors.background, letterSpacing: 0.4),
              ),
              child: const Text('CONTINUAR'),
            ),
          ),
        ],
      ),
    );
  }
}
