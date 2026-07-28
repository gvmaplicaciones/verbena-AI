import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/credits.dart';
import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/widgets/confetti_background.dart';
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
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
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
        ],
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
    _resetTimer =
        Timer(const Duration(seconds: 2), () => _avatarLongPressCount = 0);
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
              decoration: const BoxDecoration(
                  color: VerbenaColors.teal, shape: BoxShape.circle),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                          style: VerbenaText.display(
                              size: 24, color: VerbenaColors.background),
                        ),
                        if (_cadenceLabel(credits.activePlanId)
                            case final label?) ...[
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: VerbenaText.body(
                              size: 13,
                              color: VerbenaColors.background
                                  .withValues(alpha: 0.85),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: VerbenaColors.terracotta,
                      borderRadius: BorderRadius.circular(999),
                      border:
                          Border.all(color: VerbenaColors.background, width: 2),
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
  const _ModeInfo({
    required this.title,
    required this.description,
    required this.source,
    required this.imagePath,
  });

  final String title;
  final String description;
  final GenerationSource source;
  // null mientras no haya asset propio todavía (ver RemoveBackgroundSource) --
  // _ModeCard pinta un icono de relleno en vez de Image.asset en ese caso.
  final String? imagePath;
}

/// FASE 0: sustituye a las pestañas Catálogo/Libertad -- el código de
/// Catálogo (edge functions, tablas, pantallas admin, TemplatesRepository)
/// no se toca, solo se le quita el acceso desde Home. Se retoma modo a modo
/// en fases siguientes (ver GenerationSourceStatus.isComingSoon).
const _modes = [
  _ModeInfo(
    title: 'Añade o modifica algo',
    description: 'Añade algo nuevo o cambia lo que ya tienes en tu foto',
    source: AddElementSource(),
    imagePath: 'assets/modes/add_element.jpeg',
  ),
  _ModeInfo(
    title: 'Eliminar algo',
    description: 'Quita algo de tu foto, describiéndolo o marcándolo',
    source: RemoveElementSource(),
    imagePath: 'assets/modes/remove_element.jpeg',
  ),
  _ModeInfo(
    title: 'Cambiar fondo',
    description: 'Cambia el fondo de tu foto por otro distinto',
    source: ChangeBackgroundSource(),
    imagePath: 'assets/modes/change_background.jpeg',
  ),
  _ModeInfo(
    title: 'Probar un look',
    description: 'Pruébate una prenda de ropa en tu foto',
    source: TryOnSource(),
    imagePath: 'assets/modes/try_on.jpeg',
  ),
  _ModeInfo(
    title: 'Eliminar fondo',
    description: 'Quita el fondo de tu foto al instante',
    source: RemoveBackgroundSource(),
    imagePath: null,
  ),
  _ModeInfo(
    title: 'Mejorar calidad',
    description: 'Arregla y mejora la nitidez de tu foto',
    source: EnhanceQualitySource(),
    imagePath: null,
  ),
];

/// Fichas grandes en lista vertical (no grid) -- con 4 fichas de este tamaño
/// caben ~2 en pantalla y el resto se ve haciendo scroll (ya está dentro del
/// SingleChildScrollView de HomeScreen). Prioriza que la imagen se vea grande
/// para identificar el modo de un vistazo, en vez de encajar las 4 a la vez.
class _ModeGrid extends StatelessWidget {
  const _ModeGrid();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        children: [
          for (final mode in _modes) ...[
            _ModeCard(mode: mode),
            if (mode != _modes.last) const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.mode});

  final _ModeInfo mode;

  void _onTap(BuildContext context) {
    // "Eliminar algo" tiene un paso previo de elegir sub-modo (por texto /
    // marcando la zona) -- el resto de modos van directos a PhotoSelect.
    // "Añade o modifica algo" ya no tiene ese paso: siempre es un flujo
    // directo de texto (ver AddElementSource, mode por defecto .text).
    if (mode.source is RemoveElementSource) {
      context.push(AppRoutes.removeElementMode);
      return;
    }
    context.push(AppRoutes.photoSelect, extra: mode.source);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _onTap(context),
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
              child: mode.imagePath != null
                  ? Image.asset(mode.imagePath!, fit: BoxFit.contain)
                  : Container(
                      color: VerbenaColors.teal.withValues(alpha: 0.08),
                      alignment: Alignment.center,
                      child: const Icon(Icons.auto_fix_high_rounded,
                          size: 56, color: VerbenaColors.teal),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mode.title,
                      style:
                          VerbenaText.body(size: 17, weight: FontWeight.w700)),
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
