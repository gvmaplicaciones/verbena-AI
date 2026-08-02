/// Costes de crédito por generación. Ambos modos cuestan igual: cualquiera
/// de los dos contadores (tier o extra) sirve para cualquiera de los dos
/// modos, sin restricción de origen.
abstract final class CreditCosts {
  static const int catalogGeneration = 1;
  static const int libertadGeneration = 1;
}

abstract final class PlanIds {
  static const semanal = 'semanal';
  static const mensual = 'mensual';
}

abstract final class ExtraPackIds {
  static const extra7 = 'extra_7';
}

/// Identificador real del entitlement en RevenueCat (Project Settings >
/// Entitlements), confirmado contra la API de suscriptores -- no es el
/// product_id ('semanal'/'mensual'), es el nombre del entitlement al que
/// ambos productos están adjuntos.
abstract final class RevenueCatEntitlements {
  static const pro = 'verbenAI Pro';
}
