// revenuecat-reconcile
//
// Red de seguridad cliente↔RevenueCat: el cliente la llama (JWT normal de
// Supabase, no el secreto del webhook) al reanudar la app o tras "restaurar
// compras", para que user_credits no dependa únicamente de que el webhook de
// RevenueCat llegue a tiempo. Reutiliza exactamente la misma lógica de
// concesión/expiración que revenuecat-webhook (_shared/revenuecat.ts), así
// que los dos caminos nunca pueden divergir en el resultado.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
// Response: { subscriptionStatus, activePlanId }

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { reconcileSubscriberState } from "../_shared/revenuecat.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  const user = await getAuthedUser(req);
  if (!user) {
    return json({ error: "unauthorized" }, 401);
  }

  try {
    const result = await reconcileSubscriberState(supabaseAdmin(), user.id);
    return json(result);
  } catch (err) {
    console.error("revenuecat-reconcile error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
