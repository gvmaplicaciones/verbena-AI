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
//           body JSON = { event: { id, type, app_user_id, product_id?, expiration_at_ms? } }
// Response: { status: 'processed' | 'already_processed' } o { error }

import { corsHeaders } from "../_shared/cors.ts";
import { supabaseAdmin } from "../_shared/supabase.ts";
import {
  cancelSubscription,
  expireSubscription,
  grantActiveSubscription,
  grantExtraPack,
  reactivateSubscription,
  transferSubscription,
} from "../_shared/revenuecat.ts";

const EXPECTED_AUTH = Deno.env.get("REVENUECAT_WEBHOOK_AUTHORIZATION")!;

interface RevenueCatEvent {
  id: string;
  type: string;
  // Ausente en TRANSFER (usa transferred_from/transferred_to en su lugar).
  app_user_id?: string;
  product_id?: string;
  expiration_at_ms?: number | null;
  // "Transaction identifier from the store" (docs de RevenueCat) -- mismo
  // valor que store_transaction_id en GET /subscribers, usado para dedupear
  // grantExtraPack() contra reconcileSubscriberState() (ver _shared/revenuecat.ts).
  transaction_id?: string;
  // Solo presentes en TRANSFER: app_user_id(s) de origen/destino de la
  // migración del recibo (docs de RevenueCat, "event-types-and-fields").
  transferred_from?: string[];
  transferred_to?: string[];
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

  const rawBody = await req.text();
  let payload: { event?: RevenueCatEvent };
  try {
    payload = JSON.parse(rawBody);
  } catch {
    console.error("revenuecat-webhook: invalid JSON body", rawBody);
    return json({ error: "invalid JSON body" }, 400);
  }
  const event = payload.event;
  // TRANSFER no trae app_user_id -- usa transferred_from/transferred_to en su
  // lugar (ver interfaz RevenueCatEvent). Cualquier otro tipo de evento sí lo
  // exige. Bug detectado el 2026-08-05: la validación exigía app_user_id
  // incondicionalmente, así que todo TRANSFER real llegaba aquí y se
  // rechazaba con 400 en bucle (RevenueCat reintentando sin parar) sin que
  // transferSubscription() llegase nunca a ejecutarse.
  if (!event?.id || !event.type) {
    console.error("revenuecat-webhook: malformed event", rawBody);
    return json({ error: "malformed event" }, 400);
  }
  if (event.type !== "TRANSFER" && !event.app_user_id) {
    console.error("revenuecat-webhook: malformed event", rawBody);
    return json({ error: "malformed event" }, 400);
  }

  // $RCAnonymousID:... y otros IDs no-UUID llegan cuando RevenueCat no tiene
  // todavía el app_user_id real del usuario. No hay fila en user_credits para
  // este ID, así que cualquier intento de procesarlo revienta con 500 y causa
  // reintentos infinitos. Se responde 200 para que RevenueCat no reintente.
  // No aplica a TRANSFER: no tiene app_user_id, y transferSubscription() ya
  // filtra IDs no-UUID uno a uno dentro de transferred_from/transferred_to.
  const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (event.type !== "TRANSFER" && !UUID_RE.test(event.app_user_id)) {
    console.warn(`revenuecat-webhook: app_user_id no es UUID ('${event.app_user_id}'), evento ${event.id} ignorado`);
    return json({ status: "skipped", reason: "non_uuid_user_id" });
  }

  const admin = supabaseAdmin();

  // Idempotencia: RevenueCat reintenta si no respondemos 2xx a tiempo, así
  // que un mismo event.id puede llegar más de una vez. El registro se inserta
  // ANTES del procesamiento para evitar dobles concurrentes, pero se ELIMINA
  // si el procesamiento falla — así el siguiente reintento puede procesarlo.
  // app_user_id es NOT NULL en la tabla; TRANSFER no trae uno propio, así que
  // se usa el primer destino (o el primer origen si no hay destino) solo para
  // dejar rastro legible en el registro de dedupe, no se usa para lógica.
  const dedupeAppUserId = event.app_user_id ??
    event.transferred_to?.[0] ?? event.transferred_from?.[0] ?? "unknown";
  const { error: dedupeErr } = await admin
    .from("revenuecat_events")
    .insert({
      id: event.id,
      event_type: event.type,
      app_user_id: dedupeAppUserId,
      product_id: event.product_id ?? null,
    });
  if (dedupeErr) {
    if (dedupeErr.code === "23505") {
      return json({ status: "already_processed" });
    }
    console.error("revenuecat-webhook dedupe insert error", dedupeErr);
    return json({ error: "internal error" }, 500);
  }

  // Validado más arriba: presente para todo tipo salvo TRANSFER, que no lo usa.
  const userId = event.app_user_id!;

  try {
    switch (event.type) {
      case "INITIAL_PURCHASE":
      case "RENEWAL":
      case "PRODUCT_CHANGE":
        if (event.product_id) await grantActiveSubscription(admin, userId, event.product_id);
        break;
      case "UNCANCELLATION":
        await reactivateSubscription(admin, userId, event.product_id);
        break;
      case "CANCELLATION":
        await cancelSubscription(admin, userId, event.expiration_at_ms);
        break;
      case "EXPIRATION":
        await expireSubscription(admin, userId);
        break;
      case "NON_RENEWING_PURCHASE":
        if (event.product_id) await grantExtraPack(admin, userId, event.product_id, event.transaction_id);
        break;
      case "TRANSFER":
        await transferSubscription(admin, event.transferred_from ?? [], event.transferred_to ?? []);
        break;
      default:
        // BILLING_ISSUE: RevenueCat manda CANCELLATION/EXPIRATION aparte si
        // no se resuelve, nada que hacer aquí todavía. Cualquier otro tipo
        // se ignora.
        console.warn(`revenuecat-webhook: evento no manejado '${event.type}' para ${userId}`);
    }
    return json({ status: "processed" });
  } catch (err) {
    console.error("revenuecat-webhook processing error", err);
    // Elimina el registro de dedup para que RevenueCat pueda reintentar en el
    // próximo intento -- envuelto en su propio try/catch (no solo un .catch()
    // encadenado): un fallo aquí no debe impedir llegar al `return json` de
    // abajo. Incidente 2026-08-03: un evento quedó "atascado" como procesado
    // sin haber concedido nada porque este borrado no se completó, y todo
    // reintento posterior de RevenueCat chocaba con el dedupe en vez de
    // reprocesar el evento.
    try {
      await admin.from("revenuecat_events").delete().eq("id", event.id);
    } catch (deleteErr) {
      console.error("revenuecat-webhook: no se pudo eliminar dedup tras error", deleteErr);
    }
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
