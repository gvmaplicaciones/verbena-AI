import { supabaseAdmin } from "./supabase.ts";
import { encodeBase64 } from "./bytes.ts";

// Backstop de servidor para "sesión vigente mientras la app esté abierta, o
// 2-4h tras cerrarla" (el cliente no tiene por qué cerrar la sesión al
// segundo; esto es solo el TTL máximo antes de forzar re-verificación).
export const SESSION_TTL_MS = 4 * 60 * 60 * 1000;

/** Descarga un objeto privado y lo devuelve como data URI, listo para mandarlo a Replicate. */
export async function downloadAsDataUri(
  admin: ReturnType<typeof supabaseAdmin>,
  bucket: string,
  path: string,
): Promise<string> {
  const { data, error } = await admin.storage.from(bucket).download(path);
  if (error) throw error;
  const bytes = new Uint8Array(await data.arrayBuffer());
  const contentType = data.type || "image/jpeg";
  return `data:${contentType};base64,${encodeBase64(bytes)}`;
}

/** Descarga el resultado de Replicate desde su URL temporal y lo sube al bucket privado del usuario. */
export async function uploadResultImage(
  admin: ReturnType<typeof supabaseAdmin>,
  bucket: string,
  path: string,
  sourceUrl: string,
): Promise<void> {
  const res = await fetch(sourceUrl);
  if (!res.ok) {
    throw new Error(`failed to download generation result: ${res.status}`);
  }
  const bytes = new Uint8Array(await res.arrayBuffer());
  const contentType = res.headers.get("Content-Type") ?? "image/jpeg";
  const { error } = await admin.storage.from(bucket).upload(path, bytes, { contentType, upsert: true });
  if (error) throw error;
}

/**
 * Resuelve una photo_session activa + su verified_photo aprobada, verificando
 * que ambas pertenezcan al usuario autenticado. Devuelve null si la sesión no
 * es válida (expirada, de otro usuario, o la foto no está aprobada) -- nunca
 * hay que confiar en un verifiedPhotoId que mande el cliente directamente.
 */
export async function resolveActiveSession(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  photoSessionId: string,
): Promise<{ verifiedPhotoId: string; storagePath: string } | null> {
  const { data: session, error: sessionErr } = await admin
    .from("photo_sessions")
    .select("id, verified_photo_id, status, expires_at")
    .eq("id", photoSessionId)
    .eq("user_id", userId)
    .maybeSingle();
  if (sessionErr) throw sessionErr;
  if (!session || session.status !== "active" || new Date(session.expires_at) <= new Date()) {
    return null;
  }

  const { data: photo, error: photoErr } = await admin
    .from("verified_photos")
    .select("id, status, storage_path")
    .eq("id", session.verified_photo_id)
    .maybeSingle();
  if (photoErr) throw photoErr;
  if (!photo || photo.status !== "approved" || !photo.storage_path) {
    return null;
  }

  return { verifiedPhotoId: photo.id, storagePath: photo.storage_path };
}

/**
 * Devuelve la photo_session activa de una verified_photo, o crea una nueva
 * si no hay ninguna vigente. No comprueba que la foto esté aprobada --
 * eso ya lo tiene que haber hecho el caller antes de llamar aquí.
 */
export async function ensureActiveSession(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  verifiedPhotoId: string,
): Promise<{ id: string }> {
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
