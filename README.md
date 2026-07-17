# VerbenAI

App de generación de fotos con IA para el mercado español. El usuario sube
su foto y genera imágenes suyas en escenas predefinidas (modo **Catálogo**) o
mediante texto libre (modo **Libertad**).

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
time (ver `lib/core/config/env.dart`):

```
flutter run \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_ANON_KEY=... \
  --dart-define=REVENUECAT_API_KEY=... \
  --dart-define=POSTHOG_API_KEY=... \
  --dart-define=SENTRY_DSN=...
```

Para Supabase local: `supabase start` levanta Postgres + Storage + el
runtime de Edge Functions a partir de `supabase/migrations` y
`supabase/config.toml`. Las Edge Functions esperan además
`REPLICATE_API_TOKEN` como secret (`supabase secrets set REPLICATE_API_TOKEN=...`).

## Decisiones de arquitectura relevantes

- **Créditos**: dos contadores por usuario (`tier_credits`, se resetea cada
  renovación; `extra_credits`, no caduca). Ambos modos (Catálogo/Libertad)
  cuestan 1 crédito; se consume tier antes que extra.
- **Verificación de foto**: una vez por hash exacto de archivo, nunca por
  generación. Se descuenta crédito solo después de verificar con éxito.
- **Retención**: la foto verificada solo se persiste en Storage si el
  usuario tiene suscripción activa en el momento de verificar; se borra al
  recibir el evento `EXPIRATION` de RevenueCat (no en `CANCELLATION`).
- **Cifrado de Storage**: cifrado en reposo por defecto de Supabase
  (AES-256), buckets privados, acceso vía URLs firmadas desde Edge
  Functions. Sin cifrado a nivel de aplicación por ahora (ver
  `supabase/migrations/20260717000100_storage_buckets.sql`).
