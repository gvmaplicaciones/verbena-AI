import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/auth_repository.dart';
import '../router/app_routes.dart';

/// context.pop() lanza "There is nothing to pop" si la pantalla se alcanzó
/// sin nada debajo en la pila (deep link, navegación directa, o tras un
/// context.go() que resetea el stack -- visto en Sentry issue 137847204).
/// Usar esto en cualquier botón de volver/cerrar de pantalla en vez de
/// context.pop() a secas.
extension SafePop on BuildContext {
  void safePop([Object? result]) {
    if (canPop()) {
      pop(result);
    } else {
      go(AppRoutes.home);
    }
  }
}

/// Gate de registro antes de disparar una generación real (incluida la
/// gratis, no solo el pago -- decisión de producto 2026-08-05, ver
/// paywall_screen.dart._buy). Mismo patrón: si el usuario es anónimo, lo
/// manda a AccountGateScreen y solo deja continuar si vuelve `true`.
/// Reutilizado desde todos los puntos de entrada a ProcessingScreen
/// (PhotoSelectScreen, GarmentSelectScreen) para no duplicar el check.
Future<bool> ensureRegisteredForGeneration(
    BuildContext context, WidgetRef ref) async {
  if (!ref.read(authRepositoryProvider).isAnonymous) return true;
  final canProceed = await context.push<bool>(AppRoutes.accountGate);
  return canProceed == true;
}
