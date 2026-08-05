import 'dart:async';
import 'dart:developer' as developer;

import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/credits.dart';

/// Mantiene Purchases.appUserID sincronizado con el uid de Supabase durante
/// toda la vida del proceso, y dispara [onEntitlementChanged] cuando cambia
/// el entitlement activo (pago pendiente que se confirma, renovación,
/// expiración...). Sustituye a los Purchases.logIn() manuales dispersos por
/// pantallas (login, signOut, borrar cuenta, modo admin) -- con esto ninguna
/// pantalla tiene que acordarse de re-sincronizar RevenueCat, pasa solo al
/// escuchar onAuthStateChange (ver docs/rework-ios-login-suscripciones.md).
///
/// NUNCA llama a restorePurchases(): en iOS eso arrastra el recibo completo
/// del Apple ID del dispositivo al appUserID actual y dispara TRANSFER
/// (rebote de suscripción entre cuentas, visto en producción el 2026-08-05).
/// Restaurar sigue siendo una acción explícita del usuario desde el botón
/// "Restaurar compras" del paywall.
class PurchasesAuthSync {
  PurchasesAuthSync._();

  static StreamSubscription<AuthState>? _authSub;
  static String? _lastSyncedUserId;
  static bool _lastHadEntitlement = false;

  /// Llamar una vez desde main(), justo después de Purchases.configure() y
  /// antes de runApp().
  static void start(GoTrueClient auth, {Future<void> Function()? onEntitlementChanged}) {
    _lastSyncedUserId = auth.currentUser?.id;

    _authSub?.cancel();
    _authSub = auth.onAuthStateChange.listen((data) {
      final userId = data.session?.user.id;
      // Sesión cerrada sin sustituta todavía (transitorio dentro de
      // signOutAndStartFresh o del cambio a modo admin): no hay identidad
      // nueva que sincronizar aún; el evento del signIn siguiente ya traerá
      // el uid definitivo.
      if (userId == null || userId == _lastSyncedUserId) return;
      _lastSyncedUserId = userId;
      unawaited(_logInSafely(userId));
    });

    // Refresco reactivo del estado de compra (renovaciones, pagos pendientes
    // que se confirman, cambios hechos desde otro dispositivo...): el SDK
    // emite CustomerInfo cada vez que cambia; solo interesa cuando el
    // entitlement activo cambia de verdad.
    Purchases.addCustomerInfoUpdateListener((customerInfo) {
      final hasEntitlement =
          customerInfo.entitlements.active.containsKey(RevenueCatEntitlements.pro);
      if (hasEntitlement == _lastHadEntitlement) return;
      _lastHadEntitlement = hasEntitlement;
      if (onEntitlementChanged != null) unawaited(onEntitlementChanged());
    });
  }

  static Future<void> _logInSafely(String userId) async {
    try {
      await Purchases.logIn(userId);
    } catch (e, st) {
      developer.log('Purchases.logIn failed for $userId',
          name: 'PurchasesAuthSync', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'purchasesAuthSync'})));
    }
  }
}
