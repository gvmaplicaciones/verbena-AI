// delete-garment
//
// Borra una prenda del Armario: quita el objeto de Storage y la fila de
// `garments`. Escritura de negocio -- pasa por Edge Function con service
// role igual que el resto (RLS solo permite SELECT al cliente).
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { garmentId: string }
// Response: { ok: true }
//        o: { error } con 400/404/500 según el caso.

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
  if (!user) {
    return json({ error: "unauthorized" }, 401);
  }

  let body: { garmentId?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const garmentId = body.garmentId;
  if (typeof garmentId !== "string") {
    return json({ error: "garmentId is required" }, 400);
  }

  const admin = supabaseAdmin();

  try {
    const { data: garment, error: garmentErr } = await admin
      .from("garments")
      .select("id, storage_path")
      .eq("id", garmentId)
      .eq("user_id", user.id)
      .maybeSingle();
    if (garmentErr) throw garmentErr;
    if (!garment) {
      return json({ error: "garment not found" }, 404);
    }

    if (garment.storage_path) {
      const { error: removeErr } = await admin.storage.from("garments").remove([garment.storage_path]);
      if (removeErr) throw removeErr;
    }

    const { error: deleteErr } = await admin.from("garments").delete().eq("id", garmentId);
    if (deleteErr) throw deleteErr;

    return json({ ok: true });
  } catch (err) {
    console.error("delete-garment error", err);
    return json({ error: "internal error deleting garment" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
