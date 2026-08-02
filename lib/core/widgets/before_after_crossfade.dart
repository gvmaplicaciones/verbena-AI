import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Crossfade automático entre una imagen "antes" y "después" (2s por imagen,
/// ~350ms de transición) -- usado en las miniaturas de modo de Home y en el
/// hero del paywall. Se engancha a TickerMode en vez de a la ruta
/// directamente: se pausa solo mientras el widget queda tapado por otra
/// pantalla y se reanuda al volver a ser visible, sin gastar ciclos de fondo
/// mientras tanto.
class BeforeAfterCrossfade extends StatefulWidget {
  const BeforeAfterCrossfade({
    super.key,
    required this.beforeAsset,
    required this.afterAsset,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.startDelay = Duration.zero,
  });

  final String beforeAsset;
  final String afterAsset;
  final double? width;
  final double? height;
  final BoxFit fit;
  // Escalona el primer cambio cuando hay varias instancias en pantalla a la
  // vez (p.ej. las tarjetas de modo de Home), para que no crucen todas juntas.
  final Duration startDelay;

  @override
  State<BeforeAfterCrossfade> createState() => _BeforeAfterCrossfadeState();
}

class _BeforeAfterCrossfadeState extends State<BeforeAfterCrossfade> {
  static const _holdDuration = Duration(seconds: 2);
  static const _crossFadeDuration = Duration(milliseconds: 350);

  bool _showAfter = false;
  Timer? _timer;
  ValueListenable<bool>? _tickerModeNotifier;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = TickerMode.getNotifier(context);
    if (!identical(notifier, _tickerModeNotifier)) {
      _tickerModeNotifier?.removeListener(_onTickerModeChanged);
      _tickerModeNotifier = notifier..addListener(_onTickerModeChanged);
      _onTickerModeChanged();
    }
  }

  void _onTickerModeChanged() {
    if (_tickerModeNotifier!.value) {
      _scheduleNext(widget.startDelay);
    } else {
      _timer?.cancel();
    }
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      if (!mounted) return;
      setState(() => _showAfter = !_showAfter);
      _scheduleNext(_holdDuration);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tickerModeNotifier?.removeListener(_onTickerModeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedCrossFade(
      firstChild: Image.asset(
        widget.beforeAsset,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
      ),
      secondChild: Image.asset(
        widget.afterAsset,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
      ),
      crossFadeState:
          _showAfter ? CrossFadeState.showSecond : CrossFadeState.showFirst,
      duration: _crossFadeDuration,
      // Layout por defecto de AnimatedCrossFade solo estira uno de los dos
      // hijos a ancho completo (el otro se posiciona a su tamaño intrínseco,
      // anclado arriba-izquierda) -- con Positioned.fill forzamos que ambas
      // imágenes ocupen siempre la caja entera, sin huecos a la derecha.
      layoutBuilder: (topChild, topKey, bottomChild, bottomKey) => Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(key: bottomKey, child: bottomChild),
          Positioned.fill(key: topKey, child: topChild),
        ],
      ),
    );
  }
}
