import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/models/processing_args.dart';
import '../../../data/models/result_args.dart';
import '../../../data/models/verified_photo.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/generation_repository.dart';
import '../../../data/repositories/generations_repository.dart';
import '../../../data/repositories/photo_repository.dart';

enum _ErrorKind {
  rejectedPhoto,
  appealedPhoto,
  rejectedPrompt,
  insufficientCredits,
  generic
}

class _ProcessingError {
  const _ProcessingError(this.kind, [this.reason]);
  final _ErrorKind kind;
  final String? reason;
}

/// El handoff no contempla NINGÚN estado de error (ni foto rechazada, ni
/// prompt rechazado, ni créditos insuficientes, ni fallo de Replicate) --
/// son estados reales del backend que la maqueta no pinta.
/// Se añaden pantallas de error propias, avisado al usuario como el resto
/// de correcciones de contenido/lógica.
class ProcessingScreen extends ConsumerStatefulWidget {
  const ProcessingScreen({super.key, required this.args});

  final ProcessingArgs args;

  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen>
    with SingleTickerProviderStateMixin {
  // La barra simulada tarda ~_progressCap * _tickInterval en llegar al tope
  // (~30s) -- si la generación real responde antes, _run() la salta a 100%
  // igualmente; si tarda más, se queda parada en el tope y el pulso de
  // _pulseController indica que se sigue trabajando en vez de dejarla muerta.
  static const _progressCap = 95;
  static const _tickInterval = Duration(milliseconds: 315);

  bool _verifying = true;
  int _progressPct = 0;
  Timer? _progressTimer;
  _ProcessingError? _error;
  late final AnimationController _pulseController;
  // FASE 0 del grid de 4 modos (Añadir/Eliminar/Fondo/Look): todavía sin
  // backend real, ver GenerationSourceStatus.isComingSoon. Si es true, se
  // salta verify-photo y generate por completo -- no tiene sentido gastar
  // una verificación de foto para un modo que no va a hacer nada con ella.
  late final bool _comingSoon;

  @override
  void initState() {
    super.initState();
    // Construido aquí (no como inicializador lazy del campo) a propósito:
    // _pulseController solo se lee en build() cuando `stuck` es true (ver
    // más abajo), así que si el usuario sale de la pantalla antes de que la
    // barra se quede parada, dispose() sería el primer acceso al campo -- y
    // el vsync: this de un `late final` inicializado ahí busca el ancestro
    // TickerMode sobre un widget ya desactivado, reventando con "Looking up
    // a deactivated widget's ancestor is unsafe" (visto en Sentry FLUTTER-5).
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _comingSoon = widget.args.source.isComingSoon;
    if (_comingSoon) return;
    WakelockPlus.enable();
    _pulseController.repeat(reverse: true);
    _verifying = widget.args.needsVerification;
    _run();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _pulseController.dispose();
    if (!_comingSoon) WakelockPlus.disable();
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
      } catch (e, st) {
        developer.log('verifyPhoto failed',
            name: 'ProcessingScreen', error: e, stackTrace: st);
        unawaited(Sentry.captureException(e,
            stackTrace: st, hint: Hint.withMap({'stage': 'verifyPhoto'})));
        _fail(const _ProcessingError(_ErrorKind.generic));
        return;
      }
    }

    String? secondPhotoSessionId = widget.args.secondPhotoSessionId;
    if (secondPhotoSessionId == null && widget.args.secondPhotoBytes != null) {
      if (!mounted) return;
      // La primera foto puede venir ya de una sesión (needsVerification =
      // false) y saltarse el bloque de arriba -- si aun así hay segunda
      // foto que verificar, hace falta mostrar el spinner de verificación
      // igualmente, no solo cuando la primera también lo necesitaba.
      if (!_verifying) setState(() => _verifying = true);
      try {
        final secondResult =
            await ref.read(photoRepositoryProvider).verifyPhoto(
                  bytes: widget.args.secondPhotoBytes!,
                  contentType: widget.args.secondContentType!,
                );
        if (secondResult.status == VerifiedPhotoStatus.approved) {
          secondPhotoSessionId = secondResult.photoSessionId;
        } else if (secondResult.status == VerifiedPhotoStatus.rejected) {
          _fail(
              _ProcessingError(_ErrorKind.rejectedPhoto, secondResult.reason));
          return;
        } else {
          _fail(const _ProcessingError(_ErrorKind.appealedPhoto));
          return;
        }
      } catch (e, st) {
        developer.log('verifyPhoto (second) failed',
            name: 'ProcessingScreen', error: e, stackTrace: st);
        unawaited(
          Sentry.captureException(e,
              stackTrace: st,
              hint: Hint.withMap({'stage': 'verifySecondPhoto'})),
        );
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
            secondPhotoSessionId: secondPhotoSessionId,
            maskBytes: widget.args.maskBytes,
          );
      _progressTimer?.cancel();
      if (!mounted) return;

      if (!outcome.isCompleted) {
        _fail(_ProcessingError(_ErrorKind.rejectedPrompt, outcome.reason));
        return;
      }

      setState(() => _progressPct = 100);

      // myCreditsProvider y myGenerationsProvider son FutureProvider sin
      // autoDispose: sin esta invalidación, Home/Perfil siguen sirviendo la
      // respuesta cacheada de la primera carga (créditos y "Mis creaciones"
      // desactualizados) hasta que se reinicie el proceso de la app.
      ref.invalidate(myCreditsProvider);
      ref.invalidate(myGenerationsProvider);

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
    } catch (e, st) {
      developer.log('generate failed',
          name: 'ProcessingScreen', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'generate'})));
      _progressTimer?.cancel();
      _fail(const _ProcessingError(_ErrorKind.generic));
    }
  }

  // La barra avanza hasta _progressCap mientras dura la llamada real a
  // generate-catalog/generate-add-element (no hay progreso real que reportar
  // desde el backend) y salta a 100% solo cuando la respuesta llega.
  void _startProgressAnimation() {
    _progressTimer = Timer.periodic(_tickInterval, (timer) {
      if (!mounted) return;
      setState(() {
        if (_progressPct < _progressCap) _progressPct += 1;
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
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Center(
                child: _comingSoon
                    ? const _ComingSoonState()
                    : _error != null
                        ? _ErrorState(error: _error!, onRetry: _run)
                        : _buildProgressState(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressState() {
    final stuck = !_verifying && _progressPct >= _progressCap;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: _verifying
          ? [
              const SizedBox(
                width: 68,
                height: 68,
                child: CircularProgressIndicator(
                    strokeWidth: 5, color: VerbenaColors.teal),
              ),
              const SizedBox(height: 26),
              Text('Verificando tu foto', style: VerbenaText.display(size: 22)),
              const SizedBox(height: 26),
              Text(
                'Comprobando que todo esté en orden.',
                textAlign: TextAlign.center,
                style: VerbenaText.body(
                    size: 14.5, color: VerbenaColors.textMuted),
              ),
            ]
          : [
              Text('$_progressPct%',
                  style:
                      VerbenaText.display(size: 40, color: VerbenaColors.teal)),
              const SizedBox(height: 26),
              Text('Generando tu foto', style: VerbenaText.display(size: 22)),
              const SizedBox(height: 26),
              Text(
                'Puliendo los detalles, esto va que arde.',
                textAlign: TextAlign.center,
                style: VerbenaText.body(
                    size: 14.5, color: VerbenaColors.textMuted),
              ),
              const SizedBox(height: 26),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: _progressPct / 100,
                  minHeight: 12,
                  backgroundColor:
                      VerbenaColors.textDark.withValues(alpha: 0.1),
                  valueColor:
                      const AlwaysStoppedAnimation(VerbenaColors.terracotta),
                ),
              ),
              if (stuck) ...[
                const SizedBox(height: 18),
                FadeTransition(
                  opacity: _pulseController,
                  child: Text(
                    'Sigue trabajando, esto puede tardar un poco más...',
                    textAlign: TextAlign.center,
                    style: VerbenaText.body(
                        size: 13, color: VerbenaColors.textMuted),
                  ),
                ),
              ],
            ],
    );
  }
}

/// FASE 0 del grid de 4 modos: se muestra en vez del flujo de verificación/
/// generación cuando el modo todavía no está conectado a un backend real
/// (ver GenerationSourceStatus.isComingSoon).
class _ComingSoonState extends StatelessWidget {
  const _ComingSoonState();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.auto_awesome_rounded,
            size: 48, color: VerbenaColors.teal),
        const SizedBox(height: 22),
        Text('Próximamente',
            style: VerbenaText.display(size: 22), textAlign: TextAlign.center),
        const SizedBox(height: 14),
        Text(
          'Este modo todavía no está disponible. Estamos trabajando en ello.',
          textAlign: TextAlign.center,
          style: VerbenaText.body(size: 14.5, color: VerbenaColors.textMuted),
        ),
        const SizedBox(height: 28),
        TextButton(
          onPressed: () => context.go(AppRoutes.home),
          child: Text('Volver al inicio',
              style:
                  VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted)),
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
        Text(title,
            style: VerbenaText.display(size: 22), textAlign: TextAlign.center),
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
              onPressed: () => context.pushReplacement(AppRoutes.paywall,
                  extra: 'processing'),
              child: const Text('VER PLANES'),
            ),
          )
        else if (error.kind == _ErrorKind.generic)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
                onPressed: onRetry, child: const Text('REINTENTAR')),
          ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => context.go(AppRoutes.home),
          child: Text('Volver al inicio',
              style:
                  VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted)),
        ),
      ],
    );
  }
}
