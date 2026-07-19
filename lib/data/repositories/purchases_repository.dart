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

  Future<CustomerInfo> purchasePackage(Package package) => Purchases.purchasePackage(package);

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

final offeringsProvider = FutureProvider<Offerings>((ref) {
  return ref.watch(purchasesRepositoryProvider).fetchOfferings();
});
