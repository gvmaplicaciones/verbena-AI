/// Clave en SharedPreferences: si está a true, el router arranca en
/// AppRoutes.home en vez de repetir el onboarding en cada apertura.
const onboardingCompletedPrefsKey = 'onboarding_completed';

abstract final class AppRoutes {
  static const onboarding = '/onboarding';
  static const home = '/home';
  static const removeElementMode = '/remove-element-mode';
  static const photoSelect = '/photo-select';
  static const maskPainter = '/mask-painter';
  static const maskPrompt = '/mask-prompt';
  static const garmentSelect = '/garment-select';
  static const wardrobe = '/profile/wardrobe';
  static const processing = '/processing';
  static const result = '/result';
  static const paywall = '/paywall';
  static const accountGate = '/account-gate';
  static const profile = '/profile';
  static const privacyPolicy = '/profile/privacy-policy';

  // Sin entrada visible en ningún menú -- solo alcanzables vía el gesto
  // oculto en el avatar de Home (ver home_screen.dart).
  static const adminLogin = '/admin/login';
  static const adminTemplates = '/admin/templates';
  static const adminNewTemplate = '/admin/templates/new';
  static const adminCategories = '/admin/categories';
}
