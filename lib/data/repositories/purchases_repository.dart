import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants/credits.dart';
import '../providers/supabase_provider.dart';

/// El Test Store de RevenueCat expone identificadores de paquete fijos
/// ($rc_weekly/$rc_monthly/custom) que no se pueden renombrar desde el
/// dashboard -- confirmado contra la API real de RevenueCat. En producción,
/// si el offering se configura con identificadores de paquete iguales a
/// nuestros plan_id/pack_id internos, el match directo en findPackage() los
/// encuentra primero y este mapeo nunca se usa.
const _testStorePackageIdentifiers = <String, String>{
  PlanIds.semanal: r'$rc_weekly',
  PlanIds.mensual: r'$rc_monthly',
  ExtraPackIds.extra7: 'custom',
};

class PurchasesRepository {
  PurchasesRepository(this._client);

  final SupabaseClient _client;

  Future<Offerings> fetchOfferings() => Purchases.getOfferings();

  Package? findPackage(Offerings offerings, String productId) {
    final current = offerings.current;
    if (current == null) return null;
    for (final pkg in current.availablePackages) {
      if (pkg.identifier == productId || pkg.storeProduct.identifier == productId) {
        return pkg;
      }
    }
    final fallbackIdentifier = _testStorePackageIdentifiers[productId];
    if (fallbackIdentifier == null) return null;
    for (final pkg in current.availablePackages) {
      if (pkg.identifier == fallbackIdentifier) return pkg;
    }
    return null;
  }

  // Purchases.purchasePackage devuelve PurchaseResult desde purchases_flutter
  // 9.0.0 (antes CustomerInfo directo) -- se extrae aquí para no propagar el
  // cambio de tipo a paywall_screen.dart. El StoreTransaction que trae ahora
  // gratis se guarda en _lastTransactionIdentifier para que paywall_screen lo
  // loguee en AnalyticsService.purchaseCompleted justo después del await.
  Future<CustomerInfo> purchasePackage(Package package) async {
    // Migración deliberadamente mínima al subir a 10.4.2: purchase(PurchaseParams)
    // queda para una sesión aparte, no forma parte de este upgrade.
    // ignore: deprecated_member_use
    final result = await Purchases.purchasePackage(package);
    _lastTransactionIdentifier = result.storeTransaction.transactionIdentifier;
    return result.customerInfo;
  }

  String? _lastTransactionIdentifier;
  String? get lastTransactionIdentifier => _lastTransactionIdentifier;

  /// Tras una compra (o restore), sincroniza user_credits inmediatamente en
  /// vez de esperar al webhook de RevenueCat -- misma lógica server-side
  /// (_shared/revenuecat.ts vía reconcileSubscriberState), nunca puede
  /// divergir del resultado que hubiera dado el webhook.
  Future<void> reconcile() async {
    await _client.functions.invoke('revenuecat-reconcile');
  }

  Future<CustomerInfo> restorePurchases() => Purchases.restorePurchases();

  Future<CustomerInfo> getCustomerInfo() => Purchases.getCustomerInfo();
}

final purchasesRepositoryProvider = Provider<PurchasesRepository>((ref) {
  return PurchasesRepository(ref.watch(supabaseClientProvider));
});

// autoDispose (no cache indefinido): paywall_screen y profile_screen enseñan
// el precio real de la tienda leyendo esto -- con un FutureProvider normal,
// la primera llamada (justo tras Purchases.configure() en el arranque frío,
// compitiendo con que StoreKit resuelva el storefront/moneda real de la
// cuenta) se quedaba cacheada para toda la sesión sin ninguna vía de
// invalidación, así que un fetch inicial en dólares por una condición de
// carrera se veía en pantalla el resto de la sesión aunque la compra real
// (que sí usa un fetchOfferings() fresco, ver _buy() en paywall_screen) fuera
// siempre correcta. Incidente 2026-08-04: precios en $ en cuentas con región
// España confirmada. Con autoDispose se refetch cada vez que se entra a
// cualquiera de esas dos pantallas, nunca se queda pegado al resultado del
// arranque.
final offeringsProvider = FutureProvider.autoDispose<Offerings>((ref) {
  return ref.watch(purchasesRepositoryProvider).fetchOfferings();
});
