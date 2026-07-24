import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../data/models/generation_outcome.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/models/processing_args.dart';
import '../../../data/models/result_args.dart';

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
      AddElementSource() => '“${source.prompt}”',
      RemoveElementSource() => '“${source.prompt}”',
      // FASE 0: inalcanzable en la práctica (ver GenerationSourceStatus.
      // isComingSoon), solo para que el switch exhaustivo compile.
      ChangeBackgroundSource() => 'Cambiar fondo',
      TryOnSource() => 'Probar un look',
    };
  }

  Future<Uint8List> _downloadResultBytes() async {
    final request = await HttpClient().getUrl(Uri.parse(widget.args.resultUrl));
    final response = await request.close();
    return consolidateHttpClientResponseBytes(response);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sendWhatsapp() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _downloadResultBytes();
      final tempFile = File('${Directory.systemTemp.path}/verbenai_${widget.args.generationId}.jpg');
      await tempFile.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(tempFile.path)], text: 'Mira lo que me he hecho con VerbenAI 👀');
    } catch (_) {
      _showSnack('No hemos podido compartir la imagen.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveImage() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final hasAccess = await Gal.hasAccess() || await Gal.requestAccess();
      if (!hasAccess) {
        _showSnack('Necesitamos acceso a tus fotos para guardar la imagen.');
        return;
      }
      final bytes = await _downloadResultBytes();
      await Gal.putImageBytes(bytes, name: 'verbenai_${widget.args.generationId}', album: 'VerbenAI');
      _showSnack('Imagen guardada en tu galería.');
    } catch (_) {
      _showSnack('No hemos podido guardar la imagen.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _sendWhatsapp,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: VerbenaColors.whatsappGreen,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const VerbenaWhatsappIcon(size: 20),
                            const SizedBox(width: 10),
                            Text(
                              'ENVIAR POR WHATSAPP',
                              style: VerbenaText.display(size: 16, color: Colors.white, letterSpacing: 0.4),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _SecondaryButton(label: 'Guardar', onTap: _saveImage)),
                        const SizedBox(width: 8),
                        Expanded(child: _SecondaryButton(label: 'Otra vez', onTap: _generateAgain)),
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
