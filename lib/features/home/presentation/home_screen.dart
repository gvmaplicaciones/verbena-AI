import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/credits.dart';
import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/repositories/credits_repository.dart';

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

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              _HomeHeader(),
              _CreditsCard(),
              _ModeGrid(),
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

class _ModeInfo {
  const _ModeInfo({required this.title, required this.description, required this.source});

  final String title;
  final String description;
  final GenerationSource source;
}

/// FASE 0: sustituye a las pestañas Catálogo/Libertad -- el código de
/// Catálogo (edge functions, tablas, pantallas admin, TemplatesRepository)
/// no se toca, solo se le quita el acceso desde Home. Se retoma modo a modo
/// en fases siguientes (ver GenerationSourceStatus.isComingSoon).
const _modes = [
  _ModeInfo(
    title: 'Añadir algo',
    description: 'Pon un objeto, ropa o accesorio en tu foto',
    source: AddElementSource(),
  ),
  _ModeInfo(
    title: 'Eliminar algo',
    description: 'Quita algo de tu foto, describiéndolo o marcándolo',
    source: RemoveElementSource(),
  ),
  _ModeInfo(
    title: 'Cambiar fondo',
    description: 'Cambia el fondo de tu foto por otro distinto',
    source: ChangeBackgroundSource(),
  ),
  _ModeInfo(
    title: 'Probar un look',
    description: 'Pruébate una prenda de ropa en tu foto',
    source: TryOnSource(),
  ),
];

class _ModeGrid extends StatelessWidget {
  const _ModeGrid();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        children: [
          _ModeRow(modes: [_modes[0], _modes[1]]),
          const SizedBox(height: 14),
          _ModeRow(modes: [_modes[2], _modes[3]]),
        ],
      ),
    );
  }
}

/// IntrinsicHeight + stretch en vez de GridView con childAspectRatio fijo:
/// así la imagen de cada ficha es exactamente 1:1 (AspectRatio en _ModeCard)
/// y la altura de la ficha sale del contenido real, sin un número mágico que
/// aproxime "imagen + bloque de texto".
class _ModeRow extends StatelessWidget {
  const _ModeRow({required this.modes});

  final List<_ModeInfo> modes;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _ModeCard(mode: modes[0])),
          const SizedBox(width: 14),
          Expanded(child: _ModeCard(mode: modes[1])),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.mode});

  final _ModeInfo mode;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push(AppRoutes.photoSelect, extra: mode.source),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: VerbenaColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.12), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AspectRatio(aspectRatio: 1, child: _ModeImagePlaceholder()),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mode.title, style: VerbenaText.body(size: 14, weight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                    mode.description,
                    style: VerbenaText.body(size: 11.5, color: VerbenaColors.textMuted).copyWith(height: 1.25),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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

/// Sustituye a la imagen real de cada ficha hasta que la tengamos -- no hay
/// ningún asset "próximamente" en el repo todavía, así que se genera aquí
/// en vez de depender de un archivo que no existe. Cuando llegue la imagen
/// real de cada modo, esto se sustituye por un Image.asset/CachedNetworkImage
/// por ficha.
class _ModeImagePlaceholder extends StatelessWidget {
  const _ModeImagePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: VerbenaColors.teal.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome_rounded, size: 26, color: VerbenaColors.teal),
          const SizedBox(height: 6),
          Text(
            'PRÓXIMAMENTE',
            style: VerbenaText.body(size: 10, weight: FontWeight.w700, color: VerbenaColors.teal)
                .copyWith(letterSpacing: 0.6),
          ),
        ],
      ),
    );
  }
}
