import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

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
