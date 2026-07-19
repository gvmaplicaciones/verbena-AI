# Contexto de trabajo — VerbenAI

Registro de lo realizado en las últimas sesiones de trabajo con Claude Code, para retomar contexto rápido. Complementa a `CLAUDE.md` (que fija reglas de producto/negocio no negociables) — este archivo es histórico/operativo, no normativo.

---

## 1. Flujo de compra RevenueCat (Test Store) — verificado, cerrado

Se verificó de punta a punta el flujo de compra con RevenueCat en modo Test Store.

**Qué pasó:** el cliente crasheaba al intentar comprar. Se rastreó la causa hasta la versión del SDK `purchases_flutter: 8.11.0`, que es anterior a la incorporación del enum `TEST_STORE` en `purchases-android` (añadido en la 9.9.0). El SDK no reconocía el store de pruebas y fallaba al parsear la respuesta.

**Conclusión:** es un artefacto exclusivo del entorno de Test Store, no un riesgo para compras reales en producción (App Store / Play Store usan sus propios stores, no este enum). No se tocó código de producción por este hallazgo.

**Pendiente:** ninguno. Si se quiere que el Test Store funcione sin crash para seguir probando localmente, habría que subir `purchases_flutter` a una versión ≥ la que incluye `TEST_STORE` — no se ha hecho porque no bloquea producción y no se pidió explícitamente.

---

## 2. Catálogo de plantillas — 15 escenas generadas y activadas

### Objetivo
Poblar el catálogo de "Modo Catálogo" con 15 escenas reales (personaje genérico, sin personas reales) repartidas en 3 categorías: **Gamberro** (7), **Iconos culturales** (5), **Deportivo** (3, sin jugadores reales).

### La edge function no existía
El usuario asumía que `generate-template-asset` ya estaba escrita. No era así — se construyó desde cero, con autorización explícita del usuario.

**`supabase/functions/generate-template-asset/index.ts`** (nueva, ya en el repo):
- Herramienta solo de admin, nunca llamada por el cliente Flutter.
- Auth: Bearer con el propio `SUPABASE_SERVICE_ROLE_KEY` (no hay rol admin en `auth.users` todavía).
- Input: `{ categoryId, name, prompt, replicateModel?, sortOrder? }`.
- Flujo: valida categoría → genera imagen con `runTextToImage` (Replicate, `flux-1.1-pro`/`flux-dev`) → sube a bucket privado `templates` → inserta fila en tabla `templates` con **`is_active = false`** por defecto (pensado para revisión manual antes de publicar) → devuelve URL firmada de preview (24h).
- Se añadió `runTextToImage` a `_shared/replicate.ts` (aspect_ratio 3:4, jpg, safety_tolerance 2).

### Migración de categorías
`supabase/migrations/20260719000000_seed_template_categories.sql` — inserta las 3 categorías (`gamberro`, `iconos`, `deportivo`). Aplicada al remoto con `supabase db push --linked`.

### Generación de las 15 imágenes
Se generaron las 15 escenas vía scripts temporales Node (`fetch`, no `curl` — ver nota técnica abajo), todas con prompts sin nombres/personas reales:

- **Gamberro (7):** Rolex y cadena imposible · Fajos de billetes · Joyas de magnate · Anillo de campeón · Trono y corona · Coches de lujo · Portada revista económica.
- **Iconos culturales (5):** Cartel taurino · Nochevieja Puerta del Sol · Retrato años 60-70 · Cabezudo de fiestas · Portada disco de verbena.
- **Deportivo (3):** Copa en el podio · Túnel de vestuarios · Gol y confeti.

### Activación
Por instrucción explícita del usuario ("sin revisión adicional, se aprueban tal cual"), **se saltó la revisión individual** y se activaron las 15 de golpe:
```
PATCH /rest/v1/templates?is_active=eq.false  { is_active: true }
```
Resultado verificado: 15/15 filas con `is_active = true`. Como `TemplatesRepository` (Flutter) filtra `template_categories` y `templates` por `is_active = true`, las 15 plantillas ya son visibles en la app sin ningún deploy ni cambio de cliente adicional.

### Obstáculos técnicos resueltos (para no repetirlos)

1. **`supabase db push --project-ref` no existe en esta versión del CLI** → usar `--linked` (el proyecto ya está linkeado, ref `viegdekwjbrdazpegcpe`).
2. **`supabase functions logs` no existe** en esta versión del CLI — no hay forma directa de ver logs de una function desde la CLI; para diagnosticar hubo que añadir temporalmente un `debugMessage` en el catch y quitarlo después.
3. **`curl` en Windows falla en TLS** (`CRYPT_E_NO_REVOCATION_CHECK`, schannel) en este entorno. La solución "fácil" (`--ssl-no-revoke`) debilita la verificación TLS y quedó bloqueada por el clasificador de seguridad — correctamente. La solución real: usar `fetch` nativo de Node (18+) en vez de `curl` para llamadas HTTPS salientes desde script. **Usar este patrón en el futuro.**
4. **401 Unauthorized pese a usar la `service_role` key "correcta"**: Supabase tiene dos sistemas de claves en este proyecto — la JWT legacy (`eyJ...`) que se ve en algunas secciones del Dashboard, y la nueva (`sb_secret_...`, ~41 caracteres) bajo *Project Settings → API Keys → Secret keys*. La variable de entorno `SUPABASE_SERVICE_ROLE_KEY` inyectada en las Edge Functions resuelve a la **nueva**, no a la JWT legacy. Si una function admin devuelve 401 con una key "verificada como correcta" por el Dashboard, sospechar primero de esto. (Guardado en memoria persistente.)
5. **502 tras arreglar el auth**: `REPLICATE_API_TOKEN` no estaba configurado como secret en Supabase — afectaba también a `generate-catalog` y `generate-libertad`, no solo a la function nueva. Ya está seteado.
6. **429 intermitente de Replicate ("Request was throttled")**: la cuenta de Replicate tiene menos de $5 de crédito, lo que reduce el rate limit a 6 peticiones/minuto con burst de 1. Causaba ~40% de fallos en llamadas secuenciales rápidas. Solución aplicada: reintentos con backoff (3 intentos, 8s de espera) — no es un bug, es una limitación de plan/crédito de la cuenta. **Recargar crédito en Replicate eliminaría la necesidad de backoff** para trabajos futuros de generación masiva.

### Secrets/credenciales tocadas esta sesión
- `REPLICATE_API_TOKEN` — antes ausente, ahora seteado en Supabase secrets (proyecto `viegdekwjbrdazpegcpe`) y en `verbena-AI/.env` local (confirmado en `.gitignore`, nunca committeado). El token solo era visible una vez desde el dashboard de Replicate, por eso se persistió en `.env`.

---

## 3. Pendientes / próximos pasos posibles

- **Ninguna acción bloqueante pendiente** — ambas tareas (compra RevenueCat, catálogo de 15 plantillas) están cerradas y verificadas.
- Opcional: revisar visualmente en la app las 15 plantillas activadas (se activaron sin revisión individual, a petición explícita del usuario — vale la pena una pasada visual rápida cuando haya tiempo, aunque no es obligatorio).
- Opcional: recargar crédito de Replicate (actualmente <$5) si se va a hacer más generación masiva (más plantillas, testing de `generate-catalog`/`generate-libertad` en volumen) para evitar el rate-limit de 6 req/min.
- Opcional: actualizar `purchases_flutter` más allá de 8.11.0 si se quiere que el Test Store deje de crashear en pruebas locales (no afecta producción).
- Hay bastantes cambios sin commitear en el repo (ver `git status`: routing, repositorios, pantallas de onboarding/paywall/processing/result, modelos nuevos, `android/`, `ios/`, `.metadata`) que no forman parte de este trabajo — no se tocaron ni se revisaron en estas sesiones, quedan fuera del alcance de este contexto.
