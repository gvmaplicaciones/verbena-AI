// verify-photo
//
// Verifica la foto que sube el usuario (nunca la plantilla, esa la controla
// el admin). Se ejecuta UNA VEZ por archivo exacto -- identificado por su
// hash -- y el resultado se reutiliza para todas las generaciones de la
// sesión, en cualquier modo (Catálogo, Añadir algo, ...). No se descuenta
// ningún crédito aquí bajo ninguna circunstancia: eso lo hacen las funciones
// generate-*, y solo después de comprobar que hay una verificación
// aprobada.
//
// Request:  POST, Authorization: Bearer <supabase JWT, anónimo vale>
//           body = bytes crudos de la imagen
//           header Content-Type: image/jpeg | image/png | image/webp
//
// Response: { status: 'approved' | 'rejected' | 'appealed',
//             verifiedPhotoId, photoSessionId?, reason? }

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runNsfwCheck } from "../_shared/replicate.ts";
import { runCelebrityCheck } from "../_shared/aws.ts";
import { encodeBase64 } from "../_shared/bytes.ts";
import { ensureActiveSession, SESSION_TTL_MS } from "../_shared/storage.ts";

const EXT_BY_MIME: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};

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

  const fileHash = await sha256Hex(bytes);
  const admin = supabaseAdmin();

  try {
    const { data: existing, error: existingErr } = await admin
      .from("verified_photos")
      .select("id, status, storage_path")
      .eq("user_id", user.id)
      .eq("file_hash", fileHash)
      .maybeSingle();
    if (existingErr) throw existingErr;

    // approved pero sin storage_path -> cleanup-expired-photos (o la purga
    // por EXPIRATION de RevenueCat) ya borró el archivo; hay que
    // re-verificar y resubir en vez de reutilizar un caché que ya no existe
    // en Storage. El hash sigue siendo el mismo, así que se actualiza la
    // fila existente en vez de intentar un insert (violaría el unique
    // (user_id, file_hash)).
    //
    // rejected -> NO se cachea permanentemente: Rekognition no es 100%
    // determinista en coincidencias de baja confianza (confirmado con falsos
    // positivos reales ~77-81% sobre caras sintéticas). Se re-verifica de
    // cero en cada reintento -- si vuelve a rechazar, sigue rechazado; si
    // esta vez aprueba, se actualiza la fila (upsertId = existing.id).
    const needsReverify =
      (existing?.status === "approved" && !existing.storage_path) ||
      existing?.status === "rejected";
    if (existing && !needsReverify) {
      return await handleExisting(admin, user.id, existing);
    }

    return await verifyNewPhoto(admin, user.id, bytes, contentType, ext, fileHash, existing?.id);
  } catch (err) {
    console.error("verify-photo error", err);
    return json({ error: "internal error verifying photo" }, 500);
  }
});

async function handleExisting(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  existing: { id: string; status: string },
) {
  if (existing.status === "rejected") {
    return json({
      status: "rejected",
      verifiedPhotoId: existing.id,
      reason: "Esta foto ya fue rechazada en una verificación anterior.",
    });
  }

  if (existing.status === "appealed") {
    return json({ status: "appealed", verifiedPhotoId: existing.id });
  }

  // approved -> reutiliza verificación, asegura una photo_session viva
  const session = await ensureActiveSession(admin, userId, existing.id);
  return json({
    status: "approved",
    verifiedPhotoId: existing.id,
    photoSessionId: session.id,
  });
}

async function verifyNewPhoto(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  bytes: Uint8Array,
  contentType: string,
  ext: string,
  fileHash: string,
  upsertId?: string,
) {
  const dataUri = `data:${contentType};base64,${encodeBase64(bytes)}`;

  // NSFW y figuras públicas (Rekognition) corren en paralelo, no en secuencia.
  const [isNsfw, celebrityResult] = await Promise.all([
    runNsfwCheck(dataUri),
    runCelebrityCheck(bytes),
  ]);

  if (isNsfw || celebrityResult.detected) {
    const payload = {
      user_id: userId,
      file_hash: fileHash,
      status: "rejected",
      moderation_result: { nsfw: isNsfw, celebrity: celebrityResult.raw },
      is_persisted: false,
      storage_path: null,
      expires_at: null,
    };
    const { data: rejected, error } = upsertId
      ? await admin.from("verified_photos").update(payload).eq("id", upsertId).select("id").single()
      : await admin.from("verified_photos").insert(payload).select("id").single();
    if (error) throw error;

    return json({
      status: "rejected",
      verifiedPhotoId: rejected.id,
      reason: isNsfw
        ? "La foto no ha pasado la verificación de contenido."
        : "La foto no ha pasado la verificación (figura pública detectada).",
    });
  }

  // Aprobada: se guarda siempre en Storage (hace falta el binario para que
  // generate-catalog/generate-libertad llamen a Replicate más adelante).
  // is_persisted marca si sigue viva en la galería de "fotos verificadas"
  // del perfil (solo socios) o si es efímera y cleanup-expired-photos la
  // purgará al vencer expires_at.
  const { data: credits } = await admin
    .from("user_credits")
    .select("subscription_status")
    .eq("user_id", userId)
    .maybeSingle();
  const isSubscribed = credits?.subscription_status === "active";

  const storagePath = `${userId}/${fileHash}.${ext}`;
  const { error: uploadErr } = await admin.storage
    .from("verified-photos")
    .upload(storagePath, bytes, { contentType, upsert: true });
  if (uploadErr) throw uploadErr;

  const approvedPayload = {
    user_id: userId,
    file_hash: fileHash,
    storage_path: storagePath,
    is_persisted: isSubscribed,
    status: "approved",
    moderation_result: { nsfw: isNsfw, celebrity: celebrityResult.raw },
    expires_at: isSubscribed ? null : new Date(Date.now() + SESSION_TTL_MS).toISOString(),
  };
  const { data: verifiedPhoto, error: insertErr } = upsertId
    ? await admin.from("verified_photos").update(approvedPayload).eq("id", upsertId).select("id").single()
    : await admin.from("verified_photos").insert(approvedPayload).select("id").single();
  if (insertErr) throw insertErr;

  const session = await ensureActiveSession(admin, userId, verifiedPhoto.id);

  // Limitar a 10 fotos persistidas por usuario -- la más antigua se elimina si
  // se supera el límite. Suscriptores únicamente (is_persisted=true solo se
  // marca para ellos). Si falla la purga no se bloquea la respuesta: el límite
  // es una restricción de almacenamiento, no de verificación.
  if (isSubscribed) {
    await enforcePersistedPhotoLimit(admin, userId).catch((err) =>
      console.error("enforcePersistedPhotoLimit error (non-fatal)", err),
    );
  }

  return json({
    status: "approved",
    verifiedPhotoId: verifiedPhoto.id,
    photoSessionId: session.id,
  });
}

/**
 * Si el usuario tiene más de 10 fotos persistidas, elimina las más antiguas
 * hasta volver a 10. Borrado de Storage primero; si falla, no se actualiza la BD.
 */
async function enforcePersistedPhotoLimit(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
): Promise<void> {
  const { data: photos, error } = await admin
    .from("verified_photos")
    .select("id, storage_path")
    .eq("user_id", userId)
    .eq("is_persisted", true)
    .not("storage_path", "is", null)
    .order("created_at", { ascending: true });
  if (error) throw error;
  if (!photos || photos.length <= 10) return;

  const excess = photos.slice(0, photos.length - 10);
  const paths = excess
    .map((p: { storage_path: string | null }) => p.storage_path)
    .filter((p: string | null): p is string => !!p);

  if (paths.length > 0) {
    const { error: removeErr } = await admin.storage.from("verified-photos").remove(paths);
    if (removeErr) throw removeErr;
  }

  const excessIds = excess.map((p: { id: string }) => p.id);
  const { error: updateErr } = await admin
    .from("verified_photos")
    .update({ storage_path: null, is_persisted: false })
    .in("id", excessIds);
  if (updateErr) throw updateErr;
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
