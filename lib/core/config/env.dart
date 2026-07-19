/// Configuración inyectada en build time vía --dart-define (o
/// --dart-define-from-file en CI). Nunca committear claves reales: estos
/// son solo los nombres de las variables que el build debe proveer.
abstract final class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  // RevenueCat usa una API key pública distinta por plataforma (appl_... en
  // iOS, goog_... en Android) -- no existe una clave universal. La selección
  // según Platform.isIOS se hace en main.dart antes de Purchases.configure.
  static const revenueCatIosKey = String.fromEnvironment('REVENUECAT_IOS_API_KEY');
  static const revenueCatAndroidKey = String.fromEnvironment('REVENUECAT_ANDROID_API_KEY');

  static const posthogApiKey = String.fromEnvironment('POSTHOG_API_KEY');

  // Host UE por defecto (posthog.com/eu) — el mercado objetivo es España/UE,
  // conviene mantener los datos de analítica en residencia europea.
  static const posthogHost = String.fromEnvironment(
    'POSTHOG_HOST',
    defaultValue: 'https://eu.i.posthog.com',
  );

  static const sentryDsn = String.fromEnvironment('SENTRY_DSN');

  // El handoff enlaza "Política de privacidad" sin URL real detrás --
  // vacío hasta que se provea vía --dart-define, ver aviso en ProfileScreen.
  static const privacyPolicyUrl = String.fromEnvironment('PRIVACY_POLICY_URL');
}
