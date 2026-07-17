import 'package:flutter/material.dart';

import '../../../core/theme/verbena_theme.dart';

// TODO(fase C): tarjetas Semanal/Mensual (Mensual con badge "MEJOR VALOR"),
// banner de primera foto gratis condicional, recarga de 7 créditos
// condicional a suscripción activa. Integrar purchases_ui_flutter /
// purchases_flutter para el flujo real de compra vía RevenueCat, y
// registrar paywall_viewed / purchase_attempted / purchase_completed
// (ver services/analytics_service.dart).
class PaywallScreen extends StatelessWidget {
  const PaywallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Center(
        child: Text('Hazte de la peña', style: VerbenaText.display()),
      ),
    );
  }
}
