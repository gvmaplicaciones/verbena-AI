// delete-generation
//
// Borra una generación del usuario: elimina el archivo del bucket
// 'generation-results' y la fila de `generations`. Solo el propietario puede
// borrar la suya. Si el archivo ya no está en Storage (por ejemplo, ya fue
// purgado por el cron), igualmente borra la fila de la base de datos.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { generationId: string }
// Response: { ok: true }
//        o: { error } con 400/404/500

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

  let body: { generationId?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const { generationId } = body;
  if (typeof generationId !== "string") return json({ error: "generationId is required" }, 400);

  const admin = supabaseAdmin();

  try {
    const { data: gen, error: genErr } = await admin
      .from("generations")
      .select("id, result_storage_path")
      .eq("id", generationId)
      .eq("user_id", user.id)
      .maybeSingle();
    if (genErr) throw genErr;
    if (!gen) return json({ error: "generation not found" }, 404);

    if (gen.result_storage_path) {
      const { error: removeErr } = await admin.storage
        .from("generation-results")
        .remove([gen.result_storage_path]);
      if (removeErr) throw removeErr;
    }

    const { error: deleteErr } = await admin
      .from("generations")
      .delete()
      .eq("id", generationId);
    if (deleteErr) throw deleteErr;

    return json({ ok: true });
  } catch (err) {
    console.error("delete-generation error", err);
    return json({ error: "internal error deleting generation" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
