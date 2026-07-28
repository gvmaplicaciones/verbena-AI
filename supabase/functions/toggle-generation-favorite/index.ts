// toggle-generation-favorite
//
// Marca o desmarca una generación como favorita del usuario autenticado.
// Mark (isFavorite=true): comprueba el límite de 10 y devuelve 409 si se
// supera. Unmark (isFavorite=false): actualiza sin restricción; el cron
// cleanup-expired-photos se encarga de borrar las que queden fuera del top
// 30 no-favoritas.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { generationId: string, isFavorite: boolean }
// Response: { ok: true }
//        o: { error } con 400/404/409/500

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  const user = await getAuthedUser(req);
  if (!user) return json({ error: "unauthorized" }, 401);

  let body: { generationId?: unknown; isFavorite?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const { generationId, isFavorite } = body;
  if (typeof generationId !== "string") return json({ error: "generationId is required" }, 400);
  if (typeof isFavorite !== "boolean") return json({ error: "isFavorite must be boolean" }, 400);

  const admin = supabaseAdmin();

  try {
    const { data: gen, error: genErr } = await admin
      .from("generations")
      .select("id")
      .eq("id", generationId)
      .eq("user_id", user.id)
      .eq("status", "completed")
      .maybeSingle();
    if (genErr) throw genErr;
    if (!gen) return json({ error: "generation not found" }, 404);

    if (isFavorite) {
      const { count, error: countErr } = await admin
        .from("generations")
        .select("id", { count: "exact", head: true })
        .eq("user_id", user.id)
        .eq("is_favorite", true)
        .eq("status", "completed");
      if (countErr) throw countErr;
      if ((count ?? 0) >= 10) {
        return json(
          { error: "Ya tienes 10 favoritas — quita alguna antes de marcar otra" },
          409,
        );
      }
    }

    const { error: updateErr } = await admin
      .from("generations")
      .update({ is_favorite: isFavorite })
      .eq("id", generationId)
      .eq("user_id", user.id);
    if (updateErr) throw updateErr;

    return json({ ok: true });
  } catch (err) {
    console.error("toggle-generation-favorite error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
