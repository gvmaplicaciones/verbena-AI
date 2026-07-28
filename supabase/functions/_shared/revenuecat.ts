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
    console.warn(`revenuecat: product_id '${productId}' no coincide con ningún plan conocido, se ignora`);
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

/** UNCANCELLATION: se reactiva el auto-renovable antes de expirar -- no es un cobro nuevo, no toca créditos. */
export async function reactivateSubscription(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
): Promise<void> {
  await admin
    .from("user_credits")
    .update({ subscription_status: "active", updated_at: new Date().toISOString() })
    .eq("user_id", userId);
}

/** CANCELLATION: se apaga el auto-renovable pero el acceso sigue hasta EXPIRATION -- no se toca nada más. */
export async function cancelSubscription(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
): Promise<void> {
  await admin
    .from("user_credits")
    .update({ subscription_status: "cancelled", updated_at: new Date().toISOString() })
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

/**
 * NON_RENEWING_PURCHASE: pack de créditos extra (nunca caduca). Solo se
 * concede si hay suscripción activa -- defensa en profundidad, el paywall ya
 * lo bloquea del lado del cliente (regla de negocio: nunca alternativa a
 * suscribirse).
 */
export async function grantExtraPack(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  productId: string,
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

  const { data: credits, error: creditsErr } = await admin
    .from("user_credits")
    .select("tier_credits, extra_credits, subscription_status")
    .eq("user_id", userId)
    .maybeSingle();
  if (creditsErr) throw creditsErr;
  if (!credits) return;
  if (credits.subscription_status !== "active") {
    console.warn(`revenuecat: pack extra comprado por ${userId} sin suscripción activa, se ignora`);
    return;
  }

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
  const now = Date.now();

  // Cualquier entitlement con expiración nula (vitalicio) o futura cuenta
  // como activo -- el proyecto solo espera un entitlement pero esto no
  // asume su nombre concreto.
  let active: { product_identifier: string; expires_date_ms: number | null } | null = null;
  for (const key of Object.keys(entitlements)) {
    const ent = entitlements[key];
    const expiresMs = (ent.expires_date_ms ?? null) as number | null;
    if (expiresMs === null || expiresMs > now) {
      const currentBest = active?.expires_date_ms ?? Infinity;
      const candidateBest = expiresMs ?? Infinity;
      if (!active || candidateBest > currentBest) {
        active = { product_identifier: ent.product_identifier, expires_date_ms: expiresMs };
      }
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
    if (credits?.subscription_status !== "active" || credits.active_plan_id !== planId) {
      await grantActiveSubscription(admin, userId, active.product_identifier);
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
