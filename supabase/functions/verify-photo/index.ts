// verify-photo
//
// Verifica la foto que sube el usuario (nunca la plantilla, esa la controla
// el admin). Se ejecuta UNA VEZ por archivo exacto -- identificado por su
// hash -- y el resultado se reutiliza para todas las generaciones de la
// sesión, en ambos modos (Catálogo y Libertad). No se descuenta ningún
// crédito aquí bajo ninguna circunstancia: eso lo hacen generate-catalog y
// generate-libertad, y solo después de comprobar que hay una verificación
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
import { runContentFilter } from "../_shared/replicate.ts";

// Backstop de servidor para "sesión vigente mientras la app esté abierta, o
// 2-4h tras cerrarla" (el cliente no tiene por qué cerrar la sesión al
// segundo; esto es solo el TTL máximo antes de forzar re-verificación).
const SESSION_TTL_MS = 4 * 60 * 60 * 1000;

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
      .select("id, status")
      .eq("user_id", user.id)
      .eq("file_hash", fileHash)
      .maybeSingle();
    if (existingErr) throw existingErr;

    if (existing) {
      return await handleExisting(admin, user.id, existing);
    }

    return await verifyNewPhoto(admin, user.id, bytes, contentType, ext, fileHash);
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
  return json({ status: "approved", verifiedPhotoId: existing.id, photoSessionId: session.id });
}

async function ensureActiveSession(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  verifiedPhotoId: string,
) {
  const { data: active } = await admin
    .from("photo_sessions")
    .select("id, expires_at")
    .eq("user_id", userId)
    .eq("verified_photo_id", verifiedPhotoId)
    .eq("status", "active")
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();

  if (active) return active;

  const { data: created, error } = await admin
    .from("photo_sessions")
    .insert({
      user_id: userId,
      verified_photo_id: verifiedPhotoId,
      expires_at: new Date(Date.now() + SESSION_TTL_MS).toISOString(),
    })
    .select("id")
    .single();
  if (error) throw error;
  return created;
}

async function verifyNewPhoto(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  bytes: Uint8Array,
  contentType: string,
  ext: string,
  fileHash: string,
) {
  const dataUri = `data:${contentType};base64,${encodeBase64(bytes)}`;
  const result = await runContentFilter(dataUri);

  if (!result.passed) {
    const { data: rejected, error } = await admin
      .from("verified_photos")
      .insert({
        user_id: userId,
        file_hash: fileHash,
        status: "rejected",
        moderation_result: result.raw,
        is_persisted: false,
      })
      .select("id")
      .single();
    if (error) throw error;

    return json({
      status: "rejected",
      verifiedPhotoId: rejected.id,
      reason: result.reason ?? "La foto no ha pasado la verificación.",
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

  const { data: verifiedPhoto, error: insertErr } = await admin
    .from("verified_photos")
    .insert({
      user_id: userId,
      file_hash: fileHash,
      storage_path: storagePath,
      is_persisted: isSubscribed,
      status: "approved",
      moderation_result: result.raw,
      expires_at: isSubscribed ? null : new Date(Date.now() + SESSION_TTL_MS).toISOString(),
    })
    .select("id")
    .single();
  if (insertErr) throw insertErr;

  const session = await ensureActiveSession(admin, userId, verifiedPhoto.id);

  return json({
    status: "approved",
    verifiedPhotoId: verifiedPhoto.id,
    photoSessionId: session.id,
  });
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function encodeBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
