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
import 'generation_actions.dart';

String _creditLabel(GenerationCreditSource? source) => switch (source) {
      GenerationCreditSource.tier => '-1 crédito del plan',
      GenerationCreditSource.extra => '-1 crédito extra',
      GenerationCreditSource.free => 'Generación gratis usada',
      null => '-1 crédito',
    };

class ResultScreen extends ConsumerStatefulWidget {
  const ResultScreen({super.key, required this.args});

  final ResultArgs args;

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen> {
  bool _busy = false;

  String get _caption {
    final source = widget.args.source;
    return switch (source) {
      CatalogSource() => source.template.name,
      AddElementSource() => '"${source.prompt}"',
      RemoveElementSource() => '"${source.prompt}"',
      ChangeBackgroundSource() =>
        source.placeText.isEmpty ? 'Cambiar fondo' : '"${source.placeText}"',
      ModifyElementSource() => '"${source.prompt}"',
      // FASE 0: inalcanzable en la práctica (ver GenerationSourceStatus.
      // isComingSoon), solo para que el switch exhaustivo compile.
      TryOnSource() => 'Probar un look',
    };
  }

  void _generateAgain() {
    context.pushReplacement(
      AppRoutes.processing,
      extra: ProcessingArgs.fromSession(
        source: widget.args.source,
        photoSessionId: widget.args.photoSessionId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  CachedNetworkImage(
                    imageUrl: widget.args.resultUrl,
                    fit: BoxFit.contain,
                    placeholder: (context, url) =>
                        const Center(child: CircularProgressIndicator(color: Colors.white)),
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
                          _creditLabel(widget.args.creditSource),
                          style: VerbenaText.body(
                            size: 12,
                            weight: FontWeight.w600,
                            color: VerbenaColors.terracotta,
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
                            label: 'Otra vez',
                            onTap: () {
                              setState(() => _busy = true);
                              _generateAgain();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _SecondaryButton(
                            label: 'Otra plantilla',
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
