# VerbenAI — Contexto del proyecto

App de generación de fotos con IA para el mercado español. El usuario sube su 
foto y genera imágenes suyas en escenas predefinidas (modo Catálogo) o mediante 
texto libre (modo Libertad). Monetización por suscripción (RevenueCat).

## Stack
- Flutter (Riverpod + go_router), iOS + Android desde un único codebase
- Backend: Supabase (Auth anónima, Postgres, Edge Functions, Storage)
- Generación de imagen: Replicate — SIEMPRE vía Edge Functions, nunca API key en cliente
- Analítica: PostHog (host UE) · Crash reporting: Sentry
- Pagos: RevenueCat vía purchases_flutter (fijado exacto, sin `^` — ver 
  Pendientes conocidos)

## Identidad visual
Dirección "cartel vintage español". Fondo `#F3E6D0`, teal `#3D5C52`, terracota 
`#8A3324`, texto `#2B2118` / secundario `#5A4E40`, tarjetas `#FBF3E4`, verde 
WhatsApp `#25D366`. Tipografía Anton (títulos/botones, mayúsculas) + Work Sans 
(cuerpo). Handoff de diseño original en Claude Design: pantalla Home usa la 
**variante C** (tarjeta de créditos en bloque teal con badge terracota "+N 
extra" superpuesto) — nunca A ni B.

## Modelos de Replicate (confirmados)
| Modelo | Función | Coste |
|---|---|---|
| `flux-1.1-pro` / `flux-dev` | Generación de plantillas (solo admin, una vez por escena) | irrelevante en volumen |
| `lucataco/flux-content-filter` | Revisión — imagen Y texto en la misma llamada (NSFW, copyright, figuras públicas) | $0,0042 |
| `cdingram/face-swap` | Face swap — modo Catálogo | $0,012 |
| `flux-kontext-pro` | Edición por instrucciones — modo Libertad | $0,04 |

## Reglas de negocio clave (no reinterpretar sin confirmar con el usuario)

**Verificación de identidad real (crítico, no negociable)**:
- El filtro `flux-content-filter` se aplica SIEMPRE a la foto que sube el 
  usuario, en ambos modos — nunca solo al texto. En modo Libertad, además se 
  filtra el texto del prompt.
- Verificación por hash exacto del archivo, una vez por sesión, reutilizable 
  en todas las generaciones de esa sesión.
- Verificar SIEMPRE antes de descontar crédito. Si falla, no se cobra nada.
- Nunca implementar generación de personas reales identificables (figuras 
  públicas) bajo ningún argumento de disclaimer, filtro parcial o 
  responsabilidad del usuario — línea no negociable del producto.

**Créditos — dos contadores**:
- Contador de TIER: incluido en el plan (15/semana, 60/mes). Se resetea en 
  cada renovación, no se acumula.
- Contador EXTRA: comprado aparte (pack de 2,99€/7 créditos), solo disponible 
  con suscripción activa (nunca como alternativa a suscribirse). No caduca 
  nunca.
- Orden de consumo: siempre tier primero, extra solo cuando tier = 0. Se 
  permite reparto entre ambos si hace falta.
- Coste: 1 crédito = 1 generación, sin distinción de modo (catálogo y 
  libertad cuestan igual). Cualquiera de los dos contadores vale para 
  cualquiera de los dos modos.
- Free tier: 1 generación gratis total, solo en modo Catálogo, nunca en 
  Libertad.

**Retención de datos**:
- Usuarios de pago: foto guardada mientras dure la suscripción activa. 
  Borrado en evento EXPIRATION de RevenueCat (no en CANCELLATION).
- Usuarios gratuitos: no se guarda ninguna foto.
- Cifrado: en reposo por defecto de Supabase Storage (AES-256 gestionado por 
  la plataforma), sin capa propia de aplicación por ahora. Buckets privados, 
  URLs firmadas de vida corta, RLS por `user_id`. Columna `encryption_version` 
  reservada para añadir cifrado propio más adelante sin migración.
- Galería de fotos verificadas reutilizables: solo para usuarios con 
  suscripción activa.

**Precios**:
- Semanal: 4,99€ — 15 créditos de tier
- Mensual: 14,99€ — 60 créditos de tier
- Pack extra: 2,99€ — 7 créditos (solo con suscripción activa)

## Pendientes conocidos
- **Pack extra (consumible) no restaurable tras reinstalación/cambio de 
  dispositivo sin cuenta vinculada**: desde purchases_flutter 10.0.0 (Billing 
  Library 8), Google ya no permite consultar compras consumibles ya 
  consumidas, así que RevenueCat quitó el workaround que antes permitía 
  restaurarlas (ver [docs de RevenueCat](https://www.revenuecat.com/docs/known-store-issues/play-billing-library/restore-consumable-purchases-bc8)). 
  Nuestro `appUserID` es el uid anónimo de Supabase (`main.dart`), que se 
  regenera en cada reinstalación si el usuario nunca vinculó una cuenta real 
  (email/Apple/Google) — mismo caso que RevenueCat describe como "usuario 
  anónimo sin login". Afecta solo al pack extra (2,99€/7 créditos, 
  consumible); las suscripciones semanal/mensual sí se restauran vía recibo 
  de tienda independientemente del appUserID. Impacto bajo ahora mismo (pack 
  extra es una compra puntual, no la suscripción principal) — no bloquea 
  este upgrade. Se resuelve de raíz cuando exista vínculo por email 
  (mencionado como pendiente futuro en el comentario de `main.dart`), que da 
  un appUserID estable entre dispositivos/reinstalaciones.

## Convenciones de trabajo
- Nunca asumir nombres de columna sin verificar el esquema real primero.
- Toda decisión de producto/negocio no cubierta aquí: preguntar antes de 
  implementar, no asumir.
- Tras cualquier cambio en Dart: correr `flutter pub get` y `flutter analyze` 
  antes de seguir escribiendo código nuevo encima.
