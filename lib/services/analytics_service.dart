import 'package:posthog_flutter/posthog_flutter.dart';

/// Envoltorio fino sobre PostHog para no repetir nombres de evento sueltos
/// por toda la app. El embudo de pago se instrumenta desde el día 1 (fase
/// B), no se pospone: vista de paywall, intento de compra, compra
/// completada, y uso de la generación gratis.
abstract final class AnalyticsService {
  static Future<void> paywallViewed({required String source}) => Posthog().capture(
        eventName: 'paywall_viewed',
        properties: {'source': source},
      );

  static Future<void> purchaseAttempted({required String planId}) => Posthog().capture(
        eventName: 'purchase_attempted',
        properties: {'plan_id': planId},
      );

  static Future<void> purchaseCompleted({required String planId, String? transactionIdentifier}) =>
      Posthog().capture(
        eventName: 'purchase_completed',
        properties: {
          'plan_id': planId,
          if (transactionIdentifier != null) 'transaction_identifier': transactionIdentifier,
        },
      );

  static Future<void> freeGenerationUsed() => Posthog().capture(
        eventName: 'free_generation_used',
      );
}
