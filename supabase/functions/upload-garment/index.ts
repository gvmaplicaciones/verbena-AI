// upload-garment
//
// Sube una prenda nueva al Armario (solo socios, ver Profile). Pasa por el
// mismo pipeline de moderación que cualquier foto de referencia (NSFW +
// Rekognition de figuras públicas, en paralelo) -- si se rechaza, no se
// inserta fila ninguna, así que nunca ocupa uno de los MAX_GARMENTS huecos
// por usuario. A diferencia de verify-photo, aquí no hay caché por hash: cada
// subida al Armario es un alta deliberada y distinta, no una foto que se
// reutiliza sesión a sesión.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body = bytes crudos de la imagen
//           header Content-Type: image/jpeg | image/png | image/webp
//
// Response: { id, storagePath } (201)
//        o: { error, reason? } con 400/403/409/500 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runNsfwCheck } from "../_shared/replicate.ts";
import { runCelebrityCheck } from "../_shared/aws.ts";
import { encodeBase64 } from "../_shared/bytes.ts";

const EXT_BY_MIME: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};

const MAX_GARMENTS_PER_USER = 30;

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

  const contentType = req.headers.get("Content-Type") ?? "";
  const ext = EXT_BY_MIME[contentType];
  if (!ext) {
    return json(
      { error: `unsupported Content-Type '${contentType}', expected image/jpeg|png|webp` },
      400,
    );
  }

  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.byteLength === 0) {
    return json({ error: "empty request body" }, 400);
  }

  const admin = supabaseAdmin();

  try {
    // El Armario es solo para socios -- defensa en profundidad, el cliente ya
    // oculta la pantalla si no hay suscripción activa.
    const { data: credits, error: creditsErr } = await admin
      .from("user_credits")
      .select("subscription_status")
      .eq("user_id", user.id)
      .maybeSingle();
    if (creditsErr) throw creditsErr;
    if (credits?.subscription_status !== "active") {
      return json({ error: "El Armario solo está disponible para socios." }, 403);
    }

    // Límite server-side, no solo en el cliente.
    const { count, error: countErr } = await admin
      .from("garments")
      .select("id", { count: "exact", head: true })
      .eq("user_id", user.id);
    if (countErr) throw countErr;
    if ((count ?? 0) >= MAX_GARMENTS_PER_USER) {
      return json({ error: `Has alcanzado el máximo de ${MAX_GARMENTS_PER_USER} prendas en el Armario.` }, 409);
    }

    const dataUri = `data:${contentType};base64,${encodeBase64(bytes)}`;
    const [isNsfw, celebrityResult] = await Promise.all([
      runNsfwCheck(dataUri),
      runCelebrityCheck(bytes),
    ]);

    if (isNsfw || celebrityResult.detected) {
      return json({
        error: "rejected",
        reason: isNsfw
          ? "La prenda no ha pasado la verificación de contenido."
          : "La prenda no ha pasado la verificación (figura pública detectada).",
      }, 422);
    }

    const storagePath = `${user.id}/${crypto.randomUUID()}.${ext}`;
    const { error: uploadErr } = await admin.storage
      .from("garments")
      .upload(storagePath, bytes, { contentType, upsert: false });
    if (uploadErr) throw uploadErr;

    const { data: garment, error: insertErr } = await admin
      .from("garments")
      .insert({
        user_id: user.id,
        storage_path: storagePath,
        moderation_result: { nsfw: isNsfw, celebrity: celebrityResult.raw },
      })
      .select("id, storage_path")
      .single();
    if (insertErr) throw insertErr;

    return json({ id: garment.id, storagePath: garment.storage_path }, 201);
  } catch (err) {
    console.error("upload-garment error", err);
    return json({ error: "internal error uploading garment" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
