import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../data/models/processing_args.dart';
import '../../../data/models/result_args.dart';
import '../../../data/models/verified_photo.dart';
import '../../../data/repositories/generation_repository.dart';
import '../../../data/repositories/photo_repository.dart';

enum _ErrorKind { rejectedPhoto, appealedPhoto, rejectedPrompt, insufficientCredits, generic }

class _ProcessingError {
  const _ProcessingError(this.kind, [this.reason]);
  final _ErrorKind kind;
  final String? reason;
}

/// El handoff no contempla NINGÚN estado de error (ni foto rechazada, ni
/// prompt rechazado en Libertad, ni créditos insuficientes, ni fallo de
/// Replicate) -- son estados reales del backend que la maqueta no pinta.
/// Se añaden pantallas de error propias, avisado al usuario como el resto
/// de correcciones de contenido/lógica.
class ProcessingScreen extends ConsumerStatefulWidget {
  const ProcessingScreen({super.key, required this.args});

  final ProcessingArgs args;

  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen> {
  bool _verifying = true;
  int _progressPct = 0;
  Timer? _progressTimer;
  _ProcessingError? _error;

  @override
  void initState() {
    super.initState();
    _verifying = widget.args.needsVerification;
    _run();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    String? photoSessionId = widget.args.photoSessionId;

    if (photoSessionId == null) {
      if (!mounted) return;
      setState(() {
        _verifying = true;
        _error = null;
      });
      try {
        final result = await ref.read(photoRepositoryProvider).verifyPhoto(
              bytes: widget.args.photoBytes!,
              contentType: widget.args.contentType!,
            );
        if (result.status == VerifiedPhotoStatus.approved) {
          photoSessionId = result.photoSessionId;
        } else if (result.status == VerifiedPhotoStatus.rejected) {
          _fail(_ProcessingError(_ErrorKind.rejectedPhoto, result.reason));
          return;
        } else {
          _fail(const _ProcessingError(_ErrorKind.appealedPhoto));
          return;
        }
      } catch (_) {
        _fail(const _ProcessingError(_ErrorKind.generic));
        return;
      }
    }

    if (photoSessionId == null || !mounted) return;

    setState(() {
      _verifying = false;
      _progressPct = 0;
      _error = null;
    });
    _startProgressAnimation();

    try {
      final outcome = await ref.read(generationRepositoryProvider).generate(
            source: widget.args.source,
            photoSessionId: photoSessionId,
          );
      _progressTimer?.cancel();
      if (!mounted) return;

      if (!outcome.isCompleted) {
        _fail(_ProcessingError(_ErrorKind.rejectedPrompt, outcome.reason));
        return;
      }

      setState(() => _progressPct = 100);
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;

      context.pushReplacement(
        AppRoutes.result,
        extra: ResultArgs(
          source: widget.args.source,
          resultUrl: outcome.resultUrl!,
          generationId: outcome.generationId,
          photoSessionId: photoSessionId,
          creditSource: outcome.creditSource,
        ),
      );
    } on InsufficientCreditsException {
      _progressTimer?.cancel();
      _fail(const _ProcessingError(_ErrorKind.insufficientCredits));
    } catch (_) {
      _progressTimer?.cancel();
      _fail(const _ProcessingError(_ErrorKind.generic));
    }
  }

  // La barra avanza hasta el 92% mientras dura la llamada real a
  // generate-catalog/generate-libertad (no hay progreso real que reportar
  // desde el backend) y salta a 100% solo cuando la respuesta llega.
  void _startProgressAnimation() {
    _progressTimer = Timer.periodic(const Duration(milliseconds: 180), (timer) {
      if (!mounted) return;
      setState(() {
        if (_progressPct < 92) _progressPct += 4;
      });
    });
  }

  void _fail(_ProcessingError error) {
    _progressTimer?.cancel();
    if (!mounted) return;
    setState(() => _error = error);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Center(
            child: _error != null ? _ErrorState(error: _error!, onRetry: _run) : _buildProgressState(),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressState() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: _verifying
          ? [
              const SizedBox(
                width: 68,
                height: 68,
                child: CircularProgressIndicator(strokeWidth: 5, color: VerbenaColors.teal),
              ),
              const SizedBox(height: 26),
              Text('Verificando tu foto', style: VerbenaText.display(size: 22)),
              const SizedBox(height: 26),
              Text(
                'Comprobando que todo esté en orden.',
                textAlign: TextAlign.center,
                style: VerbenaText.body(size: 14.5, color: VerbenaColors.textMuted),
              ),
            ]
          : [
              Text('$_progressPct%', style: VerbenaText.display(size: 40, color: VerbenaColors.teal)),
              const SizedBox(height: 26),
              Text('Generando tu foto', style: VerbenaText.display(size: 22)),
              const SizedBox(height: 26),
              Text(
                'Puliendo los detalles, esto va que arde.',
                textAlign: TextAlign.center,
                style: VerbenaText.body(size: 14.5, color: VerbenaColors.textMuted),
              ),
              const SizedBox(height: 26),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: _progressPct / 100,
                  minHeight: 12,
                  backgroundColor: VerbenaColors.textDark.withValues(alpha: 0.1),
                  valueColor: const AlwaysStoppedAnimation(VerbenaColors.terracotta),
                ),
              ),
            ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final _ProcessingError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (title, message) = switch (error.kind) {
      _ErrorKind.rejectedPhoto => (
          'Esa foto no vale',
          error.reason ?? 'La foto no ha pasado la verificación.',
        ),
      _ErrorKind.appealedPhoto => (
          'Foto en revisión',
          'Ya has apelado esta foto -- estamos revisándola a mano.',
        ),
      _ErrorKind.rejectedPrompt => (
          'Ese prompt no vale',
          error.reason ?? 'El prompt no ha pasado la verificación.',
        ),
      _ErrorKind.insufficientCredits => (
          'Te has quedado sin créditos',
          'Consigue más créditos para seguir generando fotos.',
        ),
      _ErrorKind.generic => (
          'Algo ha ido mal',
          'No hemos podido completar la generación. Inténtalo otra vez.',
        ),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: VerbenaText.display(size: 22), textAlign: TextAlign.center),
        const SizedBox(height: 14),
        Text(
          message,
          textAlign: TextAlign.center,
          style: VerbenaText.body(size: 14.5, color: VerbenaColors.textMuted),
        ),
        const SizedBox(height: 28),
        if (error.kind == _ErrorKind.insufficientCredits)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => context.pushReplacement(AppRoutes.paywall, extra: 'processing'),
              child: const Text('VER PLANES'),
            ),
          )
        else if (error.kind == _ErrorKind.generic)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: onRetry, child: const Text('REINTENTAR')),
          ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => context.go(AppRoutes.home),
          child: Text('Volver al inicio', style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted)),
        ),
      ],
    );
  }
}
