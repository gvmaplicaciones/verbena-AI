import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
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
            content:
                Text('Ya tienes 10 favoritas — quita alguna antes de marcar otra')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No hemos podido marcar la favorita. Inténtalo otra vez.')));
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

  String get _secondaryButtonLabel =>
      widget.args.source is CatalogSource ? 'Otra plantilla' : 'Probar otra cosa';

  @override
  Widget build(BuildContext context) {
    final credits = ref.watch(myCreditsProvider).valueOrNull;
    final remainingCredits =
        credits != null ? credits.tierCredits + credits.extraCredits : null;
    return Scaffold(
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
                        final originalUrlAsync = ref
                            .watch(originalPhotoUrlProvider(widget.args.photoSessionId!));
                        return originalUrlAsync.when(
                          loading: () => CachedNetworkImage(
                            imageUrl: widget.args.resultUrl,
                            fit: BoxFit.contain,
                            placeholder: (context, url) => const Center(
                                child: CircularProgressIndicator(color: Colors.white)),
                          ),
                          error: (err, st) => CachedNetworkImage(
                            imageUrl: widget.args.resultUrl,
                            fit: BoxFit.contain,
                          ),
                          data: (beforeUrl) => BeforeAfterSlider(
                            beforeUrl: beforeUrl,
                            afterUrl: widget.args.resultUrl,
                            checkerboardAfter: widget.args.source is RemoveBackgroundSource,
                          ),
                        );
                      },
                    )
                  else
                    CachedNetworkImage(
                      imageUrl: widget.args.resultUrl,
                      fit: BoxFit.contain,
                      placeholder: (context, url) => const Center(
                          child: CircularProgressIndicator(color: Colors.white)),
                    ),
                  Positioned(
                    top: 16,
                    left: 16,
                    child: SafeArea(
                      bottom: false,
                      child: VerbenaRoundIconButton(
                        icon: const VerbenaCloseIcon(size: 16, color: Colors.white),
                        onTap: () => context.go(AppRoutes.home),
                        background: const Color(0x73000000),
                      ),
                    ),
                  ),
                  if (credits?.isSubscribed == true || credits?.freeCreditUsed == true)
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
                            style: VerbenaText.body(size: 14.5, weight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _creditLabel(widget.args.creditSource, remainingCredits),
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
        style: VerbenaText.display(size: 12.5, color: VerbenaColors.teal, letterSpacing: 0.3),
      ),
    );
  }
}
