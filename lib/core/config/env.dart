/// Configuración inyectada en build time vía --dart-define (o
/// --dart-define-from-file en CI). Nunca committear claves reales: estos
/// son solo los nombres de las variables que el build debe proveer.
abstract final class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const revenueCatApiKey = String.fromEnvironment('REVENUECAT_API_KEY');
  static const posthogApiKey = String.fromEnvironment('POSTHOG_API_KEY');

  // Host UE por defecto (posthog.com/eu) — el mercado objetivo es España/UE,
  // conviene mantener los datos de analítica en residencia europea.
  static const posthogHost = String.fromEnvironment(
    'POSTHOG_HOST',
    defaultValue: 'https://eu.i.posthog.com',
  );

  static const sentryDsn = String.fromEnvironment('SENTRY_DSN');
}
