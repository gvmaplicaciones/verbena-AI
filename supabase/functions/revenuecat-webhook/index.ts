// revenuecat-webhook
//
// Recibe los eventos server-to-server de RevenueCat y mantiene user_credits
// en sincronía: renovación/alta resetea tier_credits al total del plan
// (nunca acumula), EXPIRATION borra las fotos persistidas (nunca
// CANCELLATION, ver CLAUDE.md), NON_RENEWING_PURCHASE concede el pack extra.
// Toda la lógica de negocio vive en _shared/revenuecat.ts, compartida con
// revenuecat-reconcile para que ambos caminos nunca puedan divergir.
//
// Auth: no es un JWT de Supabase -- RevenueCat manda de vuelta, tal cual, el
// valor configurado en el dashboard como "Authorization header" del webhook.
// Se compara contra REVENUECAT_WEBHOOK_AUTHORIZATION.
//
// Request:  POST, Authorization: <valor exacto configurado en RevenueCat>
//           body JSON = { event: { id, type, app_user_id, product_id? } }
// Response: { status: 'processed' | 'already_processed' } o { error }

import { corsHeaders } from "../_shared/cors.ts";
import { supabaseAdmin } from "../_shared/supabase.ts";
import {
  cancelSubscription,
  expireSubscription,
  grantActiveSubscription,
  grantExtraPack,
  reactivateSubscription,
} from "../_shared/revenuecat.ts";

const EXPECTED_AUTH = Deno.env.get("REVENUECAT_WEBHOOK_AUTHORIZATION")!;

interface RevenueCatEvent {
  id: string;
  type: string;
  app_user_id: string;
  product_id?: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  if (req.headers.get("Authorization") !== EXPECTED_AUTH) {
    return json({ error: "unauthorized" }, 401);
  }

  let payload: { event?: RevenueCatEvent };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const event = payload.event;
  if (!event?.id || !event.type || !event.app_user_id) {
    return json({ error: "malformed event" }, 400);
  }

  const admin = supabaseAdmin();

  // Idempotencia: RevenueCat reintenta si no respondemos 2xx a tiempo, así
  // que un mismo event.id puede llegar más de una vez.
  const { error: dedupeErr } = await admin
    .from("revenuecat_events")
    .insert({ id: event.id, event_type: event.type, app_user_id: event.app_user_id });
  if (dedupeErr) {
    if (dedupeErr.code === "23505") {
      return json({ status: "already_processed" });
    }
    console.error("revenuecat-webhook dedupe insert error", dedupeErr);
    return json({ error: "internal error" }, 500);
  }

  const userId = event.app_user_id;

  try {
    switch (event.type) {
      case "INITIAL_PURCHASE":
      case "RENEWAL":
      case "PRODUCT_CHANGE":
        if (event.product_id) await grantActiveSubscription(admin, userId, event.product_id);
        break;
      case "UNCANCELLATION":
        await reactivateSubscription(admin, userId);
        break;
      case "CANCELLATION":
        await cancelSubscription(admin, userId);
        break;
      case "EXPIRATION":
        await expireSubscription(admin, userId);
        break;
      case "NON_RENEWING_PURCHASE":
        if (event.product_id) await grantExtraPack(admin, userId, event.product_id);
        break;
      default:
        // BILLING_ISSUE: RevenueCat manda CANCELLATION/EXPIRATION aparte si
        // no se resuelve, nada que hacer aquí todavía. TRANSFER: migración
        // de compra entre app_user_id -- no debería pasar con auth anónima
        // pura vinculada 1:1 (ver main.dart); pendiente de diseño si se
        // añade login real más adelante. Cualquier otro tipo se ignora.
        console.warn(`revenuecat-webhook: evento no manejado '${event.type}' para ${userId}`);
    }
    return json({ status: "processed" });
  } catch (err) {
    console.error("revenuecat-webhook processing error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
