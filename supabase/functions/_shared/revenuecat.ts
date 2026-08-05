import { supabaseAdmin } from "./supabase.ts";

const REVENUECAT_SECRET_API_KEY = Deno.env.get("REVENUECAT_SECRET_API_KEY")!;

export interface ReconcileResult {
  subscriptionStatus: "active" | "cancelled" | "expired" | "none";
  activePlanId: string | null;
}

/**
 * El Test Store de RevenueCat expone product_id fijos (weekly/monthly/
 * consumable) que no se pueden renombrar desde el dashboard -- confirmado
 * contra la API real de RevenueCat (GET /v1/subscribers/{id}/offerings). En
 * producción, si el product_id real del store ya coincide con nuestro
 * plan_id/pack_id interno, no aparece en este mapa y se usa tal cual.
 */
const TEST_STORE_PRODUCT_ID_MAP: Record<string, string> = {
  weekly: "semanal",
  monthly: "mensual",
  consumable: "extra_7",
};

function resolveInternalProductId(productId: string): string {
  return TEST_STORE_PRODUCT_ID_MAP[productId] ?? productId;
}

/**
 * Concede/renueva la suscripción: resetea tier_credits al total del plan
 * (nunca acumula, ver CLAUDE.md) y marca subscription_status='active'.
 */
export async function grantActiveSubscription(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  productId: string,
): Promise<void> {
  const planId = resolveInternalProductId(productId);
  const { data: plan, error: planErr } = await admin
    .from("plans")
    .select("plan_id, tier_credits")
    .eq("plan_id", planId)
    .eq("is_active", true)
    .maybeSingle();
  if (planErr) throw planErr;
  if (!plan) {
    console.warn(`revenuecat: product_id '${productId}' no coincide con ningún plan conocido, se ignora (user=${userId})`);
    return;
  }

  const { data: credits, error: creditsErr } = await admin
    .from("user_credits")
    .select("tier_credits, extra_credits")
    .eq("user_id", userId)
    .maybeSingle();
  if (creditsErr) throw creditsErr;
  if (!credits) return;

  await admin
    .from("user_credits")
    .update({
      tier_credits: plan.tier_credits,
      tier_total: plan.tier_credits,
      active_plan_id: plan.plan_id,
      subscription_status: "active",
      // Auto-renovable de nuevo encendido -- ninguna fecha de fin que anunciar.
      expires_at: null,
      updated_at: new Date().toISOString(),
    })
    .eq("user_id", userId);

  await admin.from("credit_transactions").insert({
    user_id: userId,
    type: "tier_reset",
    amount: plan.tier_credits - credits.tier_credits,
    balance_tier_after: plan.tier_credits,
    balance_extra_after: credits.extra_credits,
  });
}

/**
 * UNCANCELLATION: se reactiva el auto-renovable antes de expirar -- no es un
 * cobro nuevo, no toca créditos. Asume que hubo un cobro real anterior que ya
 * concedió el plan.
 *
 * Bug detectado el 2026-08-05: esa asunción no siempre es cierta -- RevenueCat
 * puede mandar CANCELLATION seguido de UNCANCELLATION como la PRIMERA
 * notificación real de una suscripción (visto en sandbox al reutilizar una
 * transacción ya conocida bajo otro app_user_id, justo antes de un TRANSFER).
 * Si nunca hubo un plan concedido (active_plan_id null) se trata como alta
 * real -- si no, un usuario de pago se queda con el status "active" pero sin
 * ninguno de sus créditos.
 */
export async function reactivateSubscription(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  productId?: string | null,
): Promise<void> {
  const { data: credits, error: creditsErr } = await admin
    .from("user_credits")
    .select("active_plan_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (creditsErr) throw creditsErr;

  if (!credits?.active_plan_id && productId) {
    await grantActiveSubscription(admin, userId, productId);
    return;
  }

  await admin
    .from("user_credits")
    .update({ subscription_status: "active", expires_at: null, updated_at: new Date().toISOString() })
    .eq("user_id", userId);
}

/**
 * CANCELLATION: se apaga el auto-renovable pero el acceso sigue hasta
 * EXPIRATION -- no se toca nada más. `expirationAtMs` (campo `expiration_at_ms`
 * del payload real de RevenueCat) es la fecha en la que ese acceso termina de
 * verdad; se guarda para poder mostrarla en cliente ("Cancelada -- activa
 * hasta [fecha]").
 */
export async function cancelSubscription(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  expirationAtMs?: number | null,
): Promise<void> {
  await admin
    .from("user_credits")
    .update({
      subscription_status: "cancelled",
      expires_at: expirationAtMs ? new Date(expirationAtMs).toISOString() : null,
      updated_at: new Date().toISOString(),
    })
    .eq("user_id", userId);
}

/**
 * EXPIRATION: fin real del período pagado. Pone tier_credits a 0 (dejan de
 * estar "incluidos en el plan" sin plan activo) y borra el archivo de las
 * fotos persistidas (is_persisted=true) del bucket -- la fila en
 * verified_photos se conserva sin storage_path para no romper el historial
 * de generations que la referencian (ver verify-photo, que ya sabe
 * re-verificar si storage_path es null). extra_credits NUNCA se toca, no
 * caduca.
 */
export async function expireSubscription(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
): Promise<void> {
  const { data: credits, error: creditsErr } = await admin
    .from("user_credits")
    .select("tier_credits, extra_credits")
    .eq("user_id", userId)
    .maybeSingle();
  if (creditsErr) throw creditsErr;
  if (!credits) return;

  await admin
    .from("user_credits")
    .update({
      tier_credits: 0,
      active_plan_id: null,
      subscription_status: "expired",
      expires_at: null,
      updated_at: new Date().toISOString(),
    })
    .eq("user_id", userId);

  if (credits.tier_credits > 0) {
    await admin.from("credit_transactions").insert({
      user_id: userId,
      type: "tier_reset",
      amount: -credits.tier_credits,
      balance_tier_after: 0,
      balance_extra_after: credits.extra_credits,
    });
  }

  await purgePersistedPhotos(admin, userId);
  await purgeGarments(admin, userId);
}

/**
 * Igual que purgePersistedPhotos pero para el Armario: el bucket 'garments'
 * es exclusivo de socios (upload-garment lo exige), así que al expirar la
 * suscripción se borran todos los archivos del usuario. Se conservan las
 * filas (storage_path a null) por la misma razón que verified_photos -- no
 * romper el historial de generations que las referencien vía garment_ids.
 */
async function purgeGarments(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
): Promise<void> {
  const { data: garments, error } = await admin
    .from("garments")
    .select("id, storage_path")
    .eq("user_id", userId)
    .not("storage_path", "is", null);
  if (error) throw error;
  if (!garments || garments.length === 0) return;

  const paths = garments.map((g: { storage_path: string | null }) => g.storage_path).filter(
    (p: string | null): p is string => !!p,
  );
  if (paths.length > 0) {
    const { error: removeErr } = await admin.storage.from("garments").remove(paths);
    if (removeErr) throw removeErr;
  }

  await admin
    .from("garments")
    .update({ storage_path: null })
    .in("id", garments.map((g: { id: string }) => g.id));
}

async function purgePersistedPhotos(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
): Promise<void> {
  const { data: photos, error } = await admin
    .from("verified_photos")
    .select("id, storage_path")
    .eq("user_id", userId)
    .eq("is_persisted", true);
  if (error) throw error;
  if (!photos || photos.length === 0) return;

  const paths = photos.map((p: { storage_path: string | null }) => p.storage_path).filter(
    (p: string | null): p is string => !!p,
  );
  if (paths.length > 0) {
    const { error: removeErr } = await admin.storage.from("verified-photos").remove(paths);
    if (removeErr) throw removeErr;
  }

  await admin
    .from("verified_photos")
    .update({ storage_path: null, is_persisted: false, expires_at: new Date().toISOString() })
    .in("id", photos.map((p: { id: string }) => p.id));
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * TRANSFER: RevenueCat migra el recibo/entitlement de un app_user_id a otro
 * -- posible desde que existe login real con Google/Apple (antes se asumía
 * que no podía pasar con auth anónima 1:1, ver comentario histórico en
 * revenuecat-webhook/index.ts). El origen (transferred_from) deja de tener
 * la suscripción: se trata igual que EXPIRATION, mismo motivo de fondo (sin
 * suscripción activa no hay base para conservar fotos/prendas persistidas).
 * El destino (transferred_to) se reconcilia contra la API en vivo de
 * RevenueCat en vez de inferir el plan aquí -- el payload de TRANSFER no
 * incluye product_id, y reconcileSubscriberState() ya sabe resolver el plan
 * real desde GET /v1/subscribers/{id}.
 */
export async function transferSubscription(
  admin: ReturnType<typeof supabaseAdmin>,
  transferredFrom: string[],
  transferredTo: string[],
): Promise<void> {
  for (const fromId of transferredFrom) {
    if (!UUID_RE.test(fromId)) continue;
    await expireSubscription(admin, fromId);
  }
  for (const toId of transferredTo) {
    if (!UUID_RE.test(toId)) continue;
    await reconcileSubscriberState(admin, toId);
  }
}

/**
 * NON_RENEWING_PURCHASE: pack de créditos extra (nunca caduca). Se concede
 * siempre que el evento llegue, sin comprobar nuestro subscription_status en
 * caché -- el paywall ya bloquea la compra en el cliente si no hay
 * suscripción activa (hasActiveAccess), y un NON_RENEWING_PURCHASE real de
 * RevenueCat ya es evidencia suficiente de un cobro real.
 *
 * Bug detectado el 2026-08-03: este guard exigía subscription_status
 * active/cancelled y lanzaba si no -- pero RevenueCat no garantiza el orden
 * de entrega de sus webhooks, así que un NON_RENEWING_PURCHASE podía llegar
 * antes que el INITIAL_PURCHASE de la misma sesión de compra, con
 * subscription_status todavía en 'expired'/'none' en ese instante. El throw
 * debía disparar un reintento (ver dedupe en revenuecat-webhook/index.ts),
 * pero el evento quedó "atascado" como procesado sin haber concedido nada,
 * perdiendo el cobro real para siempre. Confiar en el evento en vez de nuestro
 * propio caché elimina esta clase de bug de raíz.
 *
 * Bug detectado el 2026-08-04: la UI no reflejaba el pack recién comprado
 * porque myCreditsProvider se invalidaba justo tras la compra, antes de que
 * el webhook (asíncrono) hubiera concedido nada -- a diferencia de las
 * suscripciones, cuyo reconcile() concede de forma síncrona contra la API en
 * vivo de RevenueCat. reconcileSubscriberState() ahora hace lo mismo con
 * non_subscriptions, así que esta función puede recibir la misma compra por
 * dos caminos (reconcile síncrono + webhook asíncrono). `storeTransactionId`
 * (ver extra_pack_grants) dedupea para que nunca se conceda dos veces.
 */
export async function grantExtraPack(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  productId: string,
  storeTransactionId?: string | null,
): Promise<void> {
  const packId = resolveInternalProductId(productId);
  const { data: pack, error: packErr } = await admin
    .from("extra_packs")
    .select("pack_id, credits")
    .eq("pack_id", packId)
    .eq("is_active", true)
    .maybeSingle();
  if (packErr) throw packErr;
  if (!pack) {
    console.warn(`revenuecat: product_id '${productId}' no coincide con ningún pack extra conocido, se ignora`);
    return;
  }

  // Igual que el dedupe de revenuecat_events, pero por store_transaction_id
  // en vez de por event.id del webhook -- reconcile no tiene un event.id
  // (no hay webhook de por medio), así que necesita su propia clave de
  // idempotencia basada en la compra real. Si no viene (llamada antigua o
  // sin dato), se concede sin dedupe -- mismo comportamiento que antes.
  if (storeTransactionId) {
    const { error: dedupeErr } = await admin.from("extra_pack_grants").insert({
      store_transaction_id: storeTransactionId,
      user_id: userId,
      pack_id: pack.pack_id,
    });
    if (dedupeErr) {
      if (dedupeErr.code === "23505") return; // ya concedido por el otro camino
      throw dedupeErr;
    }
  }

  const { data: credits, error: creditsErr } = await admin
    .from("user_credits")
    .select("tier_credits, extra_credits, subscription_status")
    .eq("user_id", userId)
    .maybeSingle();
  if (creditsErr) throw creditsErr;
  if (!credits) return;

  const newExtra = credits.extra_credits + pack.credits;
  await admin
    .from("user_credits")
    .update({ extra_credits: newExtra, updated_at: new Date().toISOString() })
    .eq("user_id", userId);

  await admin.from("credit_transactions").insert({
    user_id: userId,
    type: "extra_purchase",
    amount: pack.credits,
    balance_tier_after: credits.tier_credits,
    balance_extra_after: newExtra,
  });
}

/**
 * Reconciliación cliente↔RevenueCat: consulta el estado real del suscriptor
 * directamente en la API de RevenueCat y aplica el mismo camino que el
 * webhook (grant/expire) si hace falta. Sirve de red de seguridad cuando el
 * webhook se retrasa o se pierde -- pensada para llamarse desde
 * revenuecat-reconcile (edge function autenticada con el JWT del usuario) al
 * reanudar la app o tras "restaurar compras".
 */
export async function reconcileSubscriberState(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
): Promise<ReconcileResult> {
  const res = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userId)}`,
    { headers: { Authorization: `Bearer ${REVENUECAT_SECRET_API_KEY}` } },
  );
  if (!res.ok) {
    throw new Error(`RevenueCat subscriber fetch failed: ${res.status} ${await res.text()}`);
  }
  const body = await res.json();
  const entitlements = body.subscriber?.entitlements ?? {};
  const subscriptions = body.subscriber?.subscriptions ?? {};
  const nonSubscriptions = body.subscriber?.non_subscriptions ?? {};
  const now = Date.now();

  // Concede packs extra (consumibles, "non_subscriptions" en la API de
  // RevenueCat) de forma síncrona, igual que ya se hace más abajo con la
  // suscripción vía `entitlements`/`subscriptions` -- así la UI no depende
  // de que el webhook NON_RENEWING_PURCHASE (asíncrono) llegue a tiempo tras
  // la compra. grantExtraPack() dedupea por store_transaction_id contra
  // extra_pack_grants, así que da igual si el webhook procesa la misma
  // compra después: no se concede dos veces. Falla en silencio (solo log)
  // por entrada -- una compra extra que no se pudo sincronizar aquí no debe
  // impedir devolver el estado de la suscripción, y el webhook sigue siendo
  // el camino que garantiza que se conceda tarde o temprano.
  //
  // `non_subscriptions` acumula TODAS las compras del pack que el usuario
  // haya hecho jamás (nunca desaparecen de la lista) -- extra_pack_grants
  // empieza vacía en este despliegue, así que sin este filtro de antigüedad
  // la primera llamada a reconcile() de cada usuario con historial re-
  // concedería TODAS sus compras pasadas ya otorgadas hace tiempo por el
  // webhook. Solo se sincroniza aquí lo comprado hace poco (recién salido de
  // purchasePackage()); lo más antiguo ya pasó por el webhook, que es quien
  // sigue siendo la fuente de verdad para todo lo que no sea "ahora mismo".
  const RECENT_PURCHASE_WINDOW_MS = 15 * 60 * 1000;
  for (const productId of Object.keys(nonSubscriptions)) {
    const purchases = nonSubscriptions[productId] as Array<{
      store_transaction_id?: string;
      purchase_date?: string;
    }>;
    for (const purchase of purchases) {
      if (!purchase.store_transaction_id) continue;
      const purchaseMs = purchase.purchase_date ? Date.parse(purchase.purchase_date) : NaN;
      if (Number.isNaN(purchaseMs) || now - purchaseMs > RECENT_PURCHASE_WINDOW_MS) continue;
      try {
        await grantExtraPack(admin, userId, productId, purchase.store_transaction_id);
      } catch (err) {
        console.error(`revenuecat: fallo al sincronizar pack extra '${productId}' (${purchase.store_transaction_id}) en reconcile`, err);
      }
    }
  }

  // Cualquier entitlement con expiración nula (vitalicio) o futura cuenta
  // como activo -- el proyecto solo espera un entitlement pero esto no
  // asume su nombre concreto.
  //
  // Bug detectado el 2026-07-31: la API real de RevenueCat
  // (GET /v1/subscribers/{id}) NUNCA devuelve `expires_date_ms` en
  // entitlements, solo `expires_date` (ISO 8601) -- leer el campo
  // inexistente hacía que expiresMs cayera siempre en null y todo
  // entitlement, caducado o no, se tratara como vitalicio. Resucitó por
  // error la suscripción de un usuario real cuyo periodo había expirado
  // el día anterior, con cada llamada a reconcile() (cada sign-in/resume).
  //
  // Bug detectado el 2026-08-05: el pack extra ('extra_7', consumible sin
  // fecha de expiración) está adjunto al mismo entitlement que los planes de
  // suscripción en el dashboard de RevenueCat, así que competía en este
  // mismo bucle y ganaba por ser "vitalicio" (expiresMs null) frente a la
  // suscripción real, que sí tiene fecha. Eso hacía que se llamase
  // grantActiveSubscription(..., 'extra_7'), que no coincide con ningún
  // plan_id y no concede nada -- el usuario se quedaba en 0/0 pese a tener
  // una suscripción real y vigente. Se filtran aquí los candidatos a solo
  // los que de verdad son un plan (tabla `plans`, is_active=true).
  const { data: activePlans, error: plansListErr } = await admin
    .from("plans")
    .select("plan_id")
    .eq("is_active", true);
  if (plansListErr) throw plansListErr;
  const validPlanIds = new Set((activePlans ?? []).map((p: { plan_id: string }) => p.plan_id));

  let active: { product_identifier: string; expires_date_ms: number | null } | null = null;
  for (const key of Object.keys(entitlements)) {
    const ent = entitlements[key] as { expires_date?: string | null; product_identifier: string };
    if (!validPlanIds.has(resolveInternalProductId(ent.product_identifier))) continue;
    const expiresMs = ent.expires_date ? Date.parse(ent.expires_date) : null;
    if (expiresMs === null || Number.isNaN(expiresMs) || expiresMs > now) {
      const currentBest = active?.expires_date_ms ?? Infinity;
      const candidateBest = expiresMs ?? Infinity;
      if (!active || candidateBest > currentBest) {
        active = { product_identifier: ent.product_identifier, expires_date_ms: expiresMs };
      }
    }
  }

  // Red de seguridad detectada el 2026-07-30, ampliada el 2026-08-05: un
  // producto puede tener una compra real y activa en `subscriptions` sin que
  // el entitlement la refleje -- ya sea porque no está adjunto en el
  // dashboard, o porque SÍ hay un entitlement pero apunta a otra cosa (p.ej.
  // el pack extra, que comparte entitlement con los planes y a veces
  // RevenueCat reporta su product_identifier como el grantor "actual" justo
  // tras comprarlo, ganándole el puesto a la suscripción real -- reproducido
  // el 2026-08-05: comprar 'extra_7' con una suscripción 'semanal' vigente
  // hizo que el filtro de `entitlements` se quedara sin candidato y
  // expireSubscription() borrase una suscripción que seguía activa).
  // `subscriptions` viene de la misma respuesta verificada de RevenueCat que
  // `entitlements` (no la manda ni la puede tocar el cliente), así que fiarse
  // de ella aquí para un producto que coincide con un plan conocido es igual
  // de seguro -- evita expirar en falso una suscripción real por un desajuste
  // de qué producto "posee" el entitlement en un instante dado.
  if (!active) {
    const activeSubKey = Object.keys(subscriptions).find((key) => {
      const sub = subscriptions[key] as { expires_date?: string | null };
      const expiresMs = sub.expires_date ? Date.parse(sub.expires_date) : null;
      return expiresMs === null || Number.isNaN(expiresMs) || expiresMs > now;
    });
    if (activeSubKey && validPlanIds.has(resolveInternalProductId(activeSubKey))) {
      const sub = subscriptions[activeSubKey] as { expires_date?: string | null };
      const expiresMs = sub.expires_date ? Date.parse(sub.expires_date) : null;
      active = { product_identifier: activeSubKey, expires_date_ms: expiresMs };
      console.warn(
        `revenuecat: user=${userId} recuperado vía 'subscriptions' -- '${activeSubKey}' no tenía entitlement válido al reconciliar (posible solape con un consumible en el mismo entitlement, ver comentario). entitlements=${
          JSON.stringify(entitlements)
        }`,
      );
    } else if (activeSubKey) {
      console.error(
        `revenuecat: MISCONFIGURACIÓN -- user=${userId} tiene una compra activa ('${activeSubKey}') en subscriptions pero no coincide con ningún plan conocido. entitlements=${
          JSON.stringify(entitlements)
        } subscriptions=${JSON.stringify(subscriptions)}. Revisar en el dashboard de RevenueCat (Product Catalog > Entitlements) que '${activeSubKey}' esté adjunto al entitlement 'verbenAI Pro'.`,
      );
    }
  }

  const { data: credits, error: creditsErr } = await admin
    .from("user_credits")
    .select("subscription_status, active_plan_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (creditsErr) throw creditsErr;

  if (active) {
    const planId = resolveInternalProductId(active.product_identifier);
    const isPlanChange = credits?.active_plan_id !== planId;
    // Solo se llama grantActiveSubscription (que resetea tier_credits) si hay
    // un cobro nuevo real: status era 'expired'/'none' (sin periodo activo) o
    // el plan cambió. Si status es 'cancelled' (periodo pagado aún en curso
    // pero sin auto-renovar) solo se reactiva el status sin tocar créditos.
    const isNewBillingPeriod =
      !credits?.subscription_status ||
      credits.subscription_status === "expired" ||
      credits.subscription_status === "none";
    if (isNewBillingPeriod || isPlanChange) {
      await grantActiveSubscription(admin, userId, active.product_identifier);
    } else if (credits.subscription_status !== "active") {
      await reactivateSubscription(admin, userId, active.product_identifier);
    }
    return { subscriptionStatus: "active", activePlanId: planId };
  }

  if (credits?.subscription_status === "active") {
    await expireSubscription(admin, userId);
    return { subscriptionStatus: "expired", activePlanId: null };
  }

  return {
    subscriptionStatus: (credits?.subscription_status as ReconcileResult["subscriptionStatus"]) ?? "none",
    activePlanId: credits?.active_plan_id ?? null,
  };
}
