// ensure-photo-session
//
// Da un photoSessionId fresco para una verified_photo ya aprobada y
// persistida (foto guardada de un socio, ver "Mis fotos verificadas" /
// "Usa una foto reciente" en PhotoSelect), sin volver a pasar por el
// filtro de contenido ni resubir bytes -- deja saltarse la verificación
// por completo al reutilizar una foto ya verificada.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { verifiedPhotoId: string }
// Response: { photoSessionId: string }

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { ensureActiveSession } from "../_shared/storage.ts";

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

  let body: { verifiedPhotoId?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const verifiedPhotoId = body.verifiedPhotoId;
  if (typeof verifiedPhotoId !== "string") {
    return json({ error: "verifiedPhotoId is required" }, 400);
  }

  const admin = supabaseAdmin();

  try {
    // Solo fotos aprobadas y persistidas del propio usuario -- nunca hay
    // que confiar en un id que mande el cliente sin comprobar ownership.
    const { data: photo, error } = await admin
      .from("verified_photos")
      .select("id")
      .eq("id", verifiedPhotoId)
      .eq("user_id", user.id)
      .eq("status", "approved")
      .eq("is_persisted", true)
      .maybeSingle();
    if (error) throw error;
    if (!photo) {
      return json({ error: "photo not found or not eligible" }, 404);
    }

    const session = await ensureActiveSession(admin, user.id, photo.id);
    return json({ photoSessionId: session.id });
  } catch (err) {
    console.error("ensure-photo-session error", err);
    return json({ error: "internal error creating photo session" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
