import { supabaseAdmin } from "./supabase.ts";
import { encodeBase64 } from "./bytes.ts";

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
