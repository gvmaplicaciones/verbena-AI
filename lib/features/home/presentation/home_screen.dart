import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/credits.dart';
import '../../../core/router/app_routes.dart';
import '../../../core/utils/date_format.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/widgets/before_after_crossfade.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/models/user_credits.dart';
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
          Text('VerbenAI', style: VerbenaText.display(size: 24)),
          Row(
            children: [
              const _ProBadge(),
              const SizedBox(width: 10),
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
        ],
      ),
    );
  }
}

/// Píldora "PRO" persistente para usuarios sin suscripción activa -- entrada
/// permanente al paywall desde Home, sin esperar a que intenten generar sin
/// créditos. Desaparece del todo para suscriptores (ver CreditsRepository).
class _ProBadge extends ConsumerWidget {
  const _ProBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasActiveAccess =
        ref.watch(myCreditsProvider).valueOrNull?.hasActiveAccess ?? false;
    if (hasActiveAccess) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => context.push(AppRoutes.paywall, extra: 'home_badge'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          // Mismo teal que el CTA "EMPEZAR" del paywall (ver
          // buildVerbenaTheme -- elevatedButtonTheme), para unificar el
          // color del botón/acción principal de compra en toda la app.
          color: VerbenaColors.teal,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'PRO',
          style: VerbenaText.display(
              size: 12.5, color: VerbenaColors.background, letterSpacing: 0.6),
        ),
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
              GestureDetector(
                onTap: () => context.push(AppRoutes.profile),
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: VerbenaColors.teal,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: _CreditsCardBody(credits: credits),
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

/// Contenido de la tarjeta de créditos según el estado real de la
/// suscripción -- nunca un "X/Y" genérico que no distinga 'cancelled' de
/// 'active' (confunde: sugeriría que se va a renovar cuando no es así).
class _CreditsCardBody extends StatelessWidget {
  const _CreditsCardBody({required this.credits});

  final UserCredits credits;

  @override
  Widget build(BuildContext context) {
    switch (credits.subscriptionStatus) {
      case 'active':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'FOTOS DE TU PLAN',
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
        );
      case 'cancelled':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SUSCRIPCIÓN',
              style: VerbenaText.body(
                size: 11,
                color: VerbenaColors.background.withValues(alpha: 0.8),
                weight: FontWeight.w500,
              ).copyWith(letterSpacing: 0.5),
            ),
            const SizedBox(height: 4),
            Text(
              credits.expiresAt != null
                  ? 'Cancelada — activa hasta ${formatShortDate(credits.expiresAt!)}'
                  : 'Cancelada — activa hasta fin de periodo',
              style: VerbenaText.display(
                  size: 17, color: VerbenaColors.background),
            ),
          ],
        );
      default: // 'expired' | 'none'
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MI PLAN',
              style: VerbenaText.body(
                size: 11,
                color: VerbenaColors.background.withValues(alpha: 0.8),
                weight: FontWeight.w500,
              ).copyWith(letterSpacing: 0.5),
            ),
            const SizedBox(height: 4),
            Text(
              credits.canUseFreeGeneration
                  ? '1 foto gratis disponible'
                  : 'Foto gratis usada — ver planes',
              style: VerbenaText.display(
                  size: 19, color: VerbenaColors.background),
            ),
          ],
        );
    }
  }
}

class _ModeInfo {
  const _ModeInfo({
    required this.title,
    required this.description,
    required this.source,
    required this.imageBaseName,
  });

  final String title;
  final String description;
  final GenerationSource source;
  // Nombre base del par before/after en assets/modes/ -- p.ej. "add" ->
  // add-before.jpg + add-after.jpg (ver _ModeThumbnail).
  final String imageBaseName;
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
    imageBaseName: 'add',
  ),
  _ModeInfo(
    title: 'Eliminar algo',
    description: 'Quita algo de tu foto, describiéndolo o marcándolo',
    source: RemoveElementSource(),
    imageBaseName: 'remove',
  ),
  _ModeInfo(
    title: 'Cambiar fondo',
    description: 'Cambia el fondo de tu foto por otro distinto',
    source: ChangeBackgroundSource(),
    imageBaseName: 'background',
  ),
  _ModeInfo(
    title: 'Probar un look',
    description: 'Pruébate una prenda de ropa en tu foto',
    source: TryOnSource(),
    imageBaseName: 'tryon',
  ),
  _ModeInfo(
    title: 'Eliminar fondo',
    description: 'Quita el fondo de tu foto al instante',
    source: RemoveBackgroundSource(),
    imageBaseName: 'removebg',
  ),
  _ModeInfo(
    title: 'Mejorar calidad',
    description: 'Arregla y mejora la nitidez de tu foto',
    source: EnhanceQualitySource(),
    imageBaseName: 'enhance',
  ),
];

/// Fichas compactas en lista vertical (miniatura + texto en fila) -- las
/// fichas cuadradas a ancho completo enterraban el resto de modos bajo un
/// scroll larguísimo (una sola ficha llenaba casi la pantalla entera).
/// Con esta altura caben al menos 2 fichas completas por pantalla.
class _ModeGrid extends StatelessWidget {
  const _ModeGrid();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        children: [
          for (final (index, mode) in _modes.indexed) ...[
            _ModeCard(mode: mode, staggerIndex: index),
            if (mode != _modes.last) const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.mode, required this.staggerIndex});

  final _ModeInfo mode;
  // Posición en el grid -- escalona el arranque del crossfade de la
  // miniatura (ver _ModeThumbnail.startDelay) para que las 6 tarjetas no
  // crucen a la vez.
  final int staggerIndex;

  void _onTap(BuildContext context) {
    context.push(AppRoutes.photoSelect, extra: mode.source);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _onTap(context),
      child: Container(
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: VerbenaColors.card,
          borderRadius: BorderRadius.circular(18),
          // Mismo borde que _PlanCard en el paywall (textDark al 15% de
          // opacidad, 1.5px, radio 18) -- las tarjetas de plan reales no
          // llevan sombra, así que no se añade ninguna aquí tampoco.
          border: Border.all(
              color: VerbenaColors.textDark.withValues(alpha: 0.15),
              width: 1.5),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _ModeThumbnail(
                imageBaseName: mode.imageBaseName,
                startDelay: Duration(milliseconds: 300 * staggerIndex),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mode.title,
                      style:
                          VerbenaText.body(size: 16, weight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    mode.description,
                    style: VerbenaText.body(
                            size: 12.5, color: VerbenaColors.textMuted)
                        .copyWith(height: 1.3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded,
                color: VerbenaColors.textDark.withValues(alpha: 0.35)),
          ],
        ),
      ),
    );
  }
}

/// Miniatura con crossfade automático before/after -- [startDelay] escalona
/// el primer cambio entre tarjetas para que no crucen las 6 a la vez.
class _ModeThumbnail extends StatelessWidget {
  const _ModeThumbnail({required this.imageBaseName, required this.startDelay});

  final String imageBaseName;
  final Duration startDelay;

  @override
  Widget build(BuildContext context) {
    // BeforeAfterCrossfade solo aplica width/height a sus Image.asset
    // internos -- su layoutBuilder los sustituye por un Stack(fit: expand)
    // que necesita constraints acotadas de un ancestro (aquí, este SizedBox;
    // en el hero del paywall, el SizedBox+Stack.expand de _PaywallHero). Sin
    // esto, dentro del Row del _ModeCard (sin Expanded) recibía constraints
    // infinitas y colapsaba a tamaño cero en release (las aserciones de
    // debug que lo habrían delatado no existen ahí).
    return SizedBox(
      width: 76,
      height: 76,
      child: BeforeAfterCrossfade(
        beforeAsset: 'assets/modes/$imageBaseName-before.jpg',
        afterAsset: 'assets/modes/$imageBaseName-after.jpg',
        startDelay: startDelay,
      ),
    );
  }
}
