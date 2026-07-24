# VerbenAI

App de generación de fotos con IA para el mercado español. El usuario sube
su foto y genera imágenes suyas en escenas predefinidas (modo **Catálogo**) o
mediante texto libre para añadir elementos (modo **Añadir algo**).

Estado: Fase B (esquema de Supabase, estructura base de Flutter, y la Edge
Function `verify-photo`). El resto de Edge Functions y la UI pixel-perfect
del handoff de diseño llegan en fases siguientes.

## Stack

- **Flutter** — un único codebase iOS/Android. Estado con Riverpod, rutas con go_router.
- **Supabase** — Auth (anónima desde el primer uso), Postgres, Edge Functions, Storage.
- **RevenueCat** (`purchases_flutter` / `purchases_ui_flutter`) — suscripciones y compra de packs extra.
- **Replicate** — generación de imagen, siempre invocada desde Edge Functions, nunca con la API key en el cliente.
- **PostHog** (analítica de producto, host UE) + **Sentry** (crash reporting) — instrumentado desde esta fase.

## Estructura

```
lib/
├── core/           # theme, router, constants, config de entorno
├── data/           # modelos + repositorios (Supabase)
├── features/       # una carpeta por pantalla (presentation/application)
├── services/       # analytics, etc.
└── widgets/        # design system compartido

supabase/
├── migrations/     # esquema de Postgres + buckets de Storage
└── functions/      # Edge Functions (Deno)
```

## Configuración local

El cliente no lee ningún `.env`: todo llega por `--dart-define` en build
time (ver `lib/core/config/env.dart`). En vez de pasar cada `--dart-define`
a mano, el repo usa un fichero `dart_define.json`:

1. `cp dart_define.example.json dart_define.json` (este fichero con valores
   reales está en `.gitignore` — nunca se commitea; `dart_define.example.json`
   sí se versiona, con las claves vacías, como plantilla).
2. Rellena `dart_define.json` con los valores reales (ver de dónde sale cada
   uno más abajo).
3. `flutter run --dart-define-from-file=dart_define.json`

### De dónde sale cada clave

| Clave | Dónde se obtiene |
|---|---|
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` | Dashboard de Supabase → el proyecto → **Project Settings → API** (`anon` `public` key, no la `service_role`). |
| `REVENUECAT_IOS_API_KEY` | Dashboard de RevenueCat → el proyecto → **API keys** → la app iOS. Empieza por `appl_`. RevenueCat usa una clave pública distinta por plataforma, no una única clave universal. |
| `REVENUECAT_ANDROID_API_KEY` | Igual que la anterior pero para la app Android del proyecto en RevenueCat. Empieza por `goog_`. |
| `POSTHOG_API_KEY` | Dashboard de PostHog → **Project Settings → Project API Key**. |
| `POSTHOG_HOST` | Opcional — si se deja vacío usa el valor por defecto (`https://eu.i.posthog.com`, residencia UE). Solo rellenar si el proyecto de PostHog vive en otra región. |
| `SENTRY_DSN` | Dashboard de Sentry → el proyecto → **Settings → Client Keys (DSN)**. |
| `PRIVACY_POLICY_URL` | URL pública de la política de privacidad (GitHub Pages). Solo se usa para rellenar el formulario de publicación de App Store Connect / Google Play Console — la app muestra el texto completo en una pantalla propia (`PrivacyPolicyScreen`), esta variable no se lee en ningún sitio de la UI. |

Para Supabase local: `supabase start` levanta Postgres + Storage + el
runtime de Edge Functions a partir de `supabase/migrations` y
`supabase/config.toml`. Las Edge Functions esperan además
`REPLICATE_API_TOKEN` como secret (`supabase secrets set REPLICATE_API_TOKEN=...`).

## Decisiones de arquitectura relevantes

- **Créditos**: dos contadores por usuario (`tier_credits`, se resetea cada
  renovación; `extra_credits`, no caduca). Cualquier modo de generación
  cuesta 1 crédito; se consume tier antes que extra. Hay además una única
  generación gratis por usuario, válida en cualquier modo.
- **Verificación de foto**: una vez por hash exacto de archivo, nunca por
  generación. Se descuenta crédito solo después de verificar con éxito.
- **Retención**: la foto verificada solo se persiste en Storage si el
  usuario tiene suscripción activa en el momento de verificar; se borra al
  recibir el evento `EXPIRATION` de RevenueCat (no en `CANCELLATION`).
- **Cifrado de Storage**: cifrado en reposo por defecto de Supabase
  (AES-256), buckets privados, acceso vía URLs firmadas desde Edge
  Functions. Sin cifrado a nivel de aplicación por ahora (ver
  `supabase/migrations/20260717000100_storage_buckets.sql`).
