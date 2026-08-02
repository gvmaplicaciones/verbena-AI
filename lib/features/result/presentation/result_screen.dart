import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/navigation.dart';
import '../../../data/models/generation_outcome.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/models/processing_args.dart';
import '../../../data/models/result_args.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/generations_repository.dart';
import '../../../data/repositories/photo_repository.dart';
import 'before_after_slider.dart';
import 'generation_actions.dart';

// El "-1 crédito" en terracota se leía como un error/coste negativo -- se
// cambia a un tono neutro con el saldo restante (más tranquilizador),
// reservando terracota para errores reales. La excepción es la gratis: ahí
// no hay saldo que enseñar, solo confirmar que se usó.
String _creditLabel(GenerationCreditSource? source, int? remainingCredits) {
  if (source == GenerationCreditSource.free) return 'Generación gratis usada';
  if (remainingCredits == null) return '';
  return 'Te quedan $remainingCredits crédito${remainingCredits == 1 ? '' : 's'}';
}

const proactivePaywallShownPrefsKey = 'proactive_paywall_shown';
const successfulGenerationsCountPrefsKey = 'successful_generations_count';
const inAppReviewRequestedPrefsKey = 'in_app_review_requested';

// Flag en memoria (no persistido): representa "esta sesión de la app". Se
// resetea solo con reiniciar la app, para que la reseña nunca se pida en la
// misma sesión en la que ya se mostró el paywall proactivo (ver
// ResultScreen._trackSuccessfulGeneration) y en su lugar espere a la
// siguiente generación exitosa, tal como se pidió.
bool _proactivePaywallShownThisSession = false;

class ResultScreen extends ConsumerStatefulWidget {
  const ResultScreen({super.key, required this.args});

  final ResultArgs args;

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen> {
  bool _busy = false;
  bool _isFavorite = false;
  bool _favoriteBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_trackSuccessfulGeneration());
  }

  // Solo tras la 2ª generación exitosa del usuario (la 1ª ya dispara el
  // paywall proactivo, ver _maybeShowProactivePaywall) se solicita la reseña
  // nativa. Google/Apple deciden internamente si la muestran -- aquí solo se
  // pide, sin diálogo propio de fallback (prohibido por políticas de tienda).
  Future<void> _trackSuccessfulGeneration() async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(successfulGenerationsCountPrefsKey) ?? 0) + 1;
    await prefs.setInt(successfulGenerationsCountPrefsKey, count);

    if (count < 2) return;
    if (prefs.getBool(inAppReviewRequestedPrefsKey) ?? false) return;
    if (_proactivePaywallShownThisSession) return;

    final inAppReview = InAppReview.instance;
    if (!await inAppReview.isAvailable()) return;
    await prefs.setBool(inAppReviewRequestedPrefsKey, true);
    await inAppReview.requestReview();
  }

  // Tras la 1ª generación gratuita (creditSource == free se agota una sola
  // vez por usuario, ver reglas de negocio en CLAUDE.md), muestra el paywall
  // completo una única vez al salir de ResultScreen -- nunca bloquea la
  // salida, el propio X del paywall permite cerrarlo sin comprar.
  Future<void> _maybeShowProactivePaywall() async {
    if (widget.args.creditSource != GenerationCreditSource.free) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(proactivePaywallShownPrefsKey) ?? false) return;
    await prefs.setBool(proactivePaywallShownPrefsKey, true);
    _proactivePaywallShownThisSession = true;
    if (!mounted) return;
    await context.push<void>(AppRoutes.paywall, extra: 'first_generation');
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteBusy) return;
    setState(() => _favoriteBusy = true);
    final next = !_isFavorite;
    try {
      await ref
          .read(generationsRepositoryProvider)
          .toggleFavorite(widget.args.generationId, next);
      if (mounted) {
        setState(() => _isFavorite = next);
        ref.invalidate(myGenerationsProvider);
      }
    } on FavoriteLimitException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Ya tienes 10 favoritas — quita alguna antes de marcar otra')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'No hemos podido marcar la favorita. Inténtalo otra vez.')));
      }
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  String get _caption {
    final source = widget.args.source;
    return switch (source) {
      CatalogSource() => source.template.name,
      AddElementSource() => '"${source.prompt}"',
      RemoveElementSource() => '"${source.prompt}"',
      ChangeBackgroundSource() =>
        source.placeText.isEmpty ? 'Cambiar fondo' : '"${source.placeText}"',
      ModifyElementSource() => '"${source.prompt}"',
      TryOnSource() => 'Probar un look',
      RemoveBackgroundSource() => 'Eliminar fondo',
      EnhanceQualitySource() => 'Mejorar calidad',
    };
  }

  void _generateAgain() {
    final sessionId = widget.args.photoSessionId;
    if (sessionId != null) {
      context.pushReplacement(
        AppRoutes.processing,
        extra: ProcessingArgs.fromSession(
          source: widget.args.source,
          photoSessionId: sessionId,
        ),
      );
    } else {
      // Modos sin verify-photo (RemoveBackground, EnhanceQuality): los bytes
      // originales no se conservan entre pantallas, así que "Otra vez" vuelve
      // a selección de foto en vez de re-procesar.
      context.go(AppRoutes.photoSelect, extra: widget.args.source);
    }
  }

  String get _secondaryButtonLabel => widget.args.source is CatalogSource
      ? 'Otra plantilla'
      : 'Probar otra cosa';

  @override
  Widget build(BuildContext context) {
    final credits = ref.watch(myCreditsProvider).valueOrNull;
    final remainingCredits =
        credits != null ? credits.tierCredits + credits.extraCredits : null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _maybeShowProactivePaywall();
        if (context.mounted) context.safePop();
      },
      child: Scaffold(
        backgroundColor: VerbenaColors.background,
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: const Color(0xFF2B2118)),
                    if (widget.args.photoSessionId != null)
                      Consumer(
                        builder: (context, ref, _) {
                          final originalUrlAsync = ref.watch(
                              originalPhotoUrlProvider(
                                  widget.args.photoSessionId!));
                          return originalUrlAsync.when(
                            loading: () => CachedNetworkImage(
                              imageUrl: widget.args.resultUrl,
                              fit: BoxFit.contain,
                              placeholder: (context, url) => const Center(
                                  child: CircularProgressIndicator(
                                      color: Colors.white)),
                            ),
                            error: (err, st) => CachedNetworkImage(
                              imageUrl: widget.args.resultUrl,
                              fit: BoxFit.contain,
                            ),
                            data: (beforeUrl) => BeforeAfterSlider(
                              beforeUrl: beforeUrl,
                              afterUrl: widget.args.resultUrl,
                              checkerboardAfter:
                                  widget.args.source is RemoveBackgroundSource,
                            ),
                          );
                        },
                      )
                    else if (widget.args.beforeBytes != null)
                      BeforeAfterSlider(
                        beforeBytes: widget.args.beforeBytes,
                        afterUrl: widget.args.resultUrl,
                        checkerboardAfter:
                            widget.args.source is RemoveBackgroundSource,
                      )
                    else
                      CachedNetworkImage(
                        imageUrl: widget.args.resultUrl,
                        fit: BoxFit.contain,
                        placeholder: (context, url) => const Center(
                            child:
                                CircularProgressIndicator(color: Colors.white)),
                      ),
                    Positioned(
                      top: 16,
                      left: 16,
                      child: SafeArea(
                        bottom: false,
                        child: VerbenaRoundIconButton(
                          icon: const VerbenaCloseIcon(
                              size: 16, color: Colors.white),
                          onTap: () async {
                            await _maybeShowProactivePaywall();
                            if (context.mounted) context.go(AppRoutes.home);
                          },
                          background: const Color(0x73000000),
                        ),
                      ),
                    ),
                    if (credits?.hasActiveAccess == true ||
                        credits?.freeCreditUsed == true)
                      Positioned(
                        top: 16,
                        right: 16,
                        child: SafeArea(
                          bottom: false,
                          child: VerbenaRoundIconButton(
                            icon: Icon(
                              _isFavorite ? Icons.star : Icons.star_border,
                              size: 18,
                              color: _isFavorite ? Colors.amber : Colors.white,
                            ),
                            onTap: _toggleFavorite,
                            background: const Color(0x73000000),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              AbsorbPointer(
                absorbing: _busy,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              _caption,
                              style: VerbenaText.body(
                                  size: 14.5, weight: FontWeight.w700),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _creditLabel(
                                widget.args.creditSource, remainingCredits),
                            style: VerbenaText.body(
                              size: 12,
                              weight: FontWeight.w600,
                              color: VerbenaColors.teal,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      GenerationShareActions(
                        resultUrl: widget.args.resultUrl,
                        generationId: widget.args.generationId,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _SecondaryButton(
                              label: 'Otra vez · 1 crédito',
                              onTap: () {
                                setState(() => _busy = true);
                                _generateAgain();
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _SecondaryButton(
                              label: _secondaryButtonLabel,
                              onTap: () => context.go(AppRoutes.home),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: VerbenaColors.teal, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 13),
      ),
      child: Text(
        label.toUpperCase(),
        textAlign: TextAlign.center,
        style: VerbenaText.display(
            size: 12.5, color: VerbenaColors.teal, letterSpacing: 0.3),
      ),
    );
  }
}
