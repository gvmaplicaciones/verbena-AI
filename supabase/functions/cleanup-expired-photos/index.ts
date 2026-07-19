// cleanup-expired-photos
//
// Job periódico (pg_cron -> pg_net, o cualquier scheduler externo) que purga
// del bucket 'verified-photos' las fotos efímeras (is_persisted=false, de
// usuarios sin suscripción activa) cuya expires_at ya venció. Nunca borra la
// fila de verified_photos -- solo el archivo -- para no romper el historial
// de photo_sessions/generations que la referencian (esas FKs no tienen
// cascade hasta generations). verify-photo ya sabe re-verificar si
// storage_path queda a null.
//
// Auth: no es un JWT de usuario -- protegida por un secreto compartido que
// solo conoce el scheduler, comparado contra CRON_SECRET.
//
// Request:  POST, Authorization: Bearer <CRON_SECRET>
// Response: { purgedPhotos, expiredSessions }

import { corsHeaders } from "../_shared/cors.ts";
import { supabaseAdmin } from "../_shared/supabase.ts";

const EXPECTED_AUTH = `Bearer ${Deno.env.get("CRON_SECRET")!}`;
const BATCH_SIZE = 500;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }
  if (req.headers.get("Authorization") !== EXPECTED_AUTH) {
    return json({ error: "unauthorized" }, 401);
  }

  const admin = supabaseAdmin();
  const nowIso = new Date().toISOString();

  try {
    const purgedPhotos = await purgeExpiredPhotos(admin, nowIso);
    const expiredSessions = await expireStaleSessions(admin, nowIso);
    return json({ purgedPhotos, expiredSessions });
  } catch (err) {
    console.error("cleanup-expired-photos error", err);
    return json({ error: "internal error" }, 500);
  }
});

async function purgeExpiredPhotos(admin: ReturnType<typeof supabaseAdmin>, nowIso: string): Promise<number> {
  const { data: photos, error } = await admin
    .from("verified_photos")
    .select("id, storage_path")
    .eq("is_persisted", false)
    .not("storage_path", "is", null)
    .not("expires_at", "is", null)
    .lt("expires_at", nowIso)
    .limit(BATCH_SIZE);
  if (error) throw error;
  if (!photos || photos.length === 0) return 0;

  const paths = photos.map((p: { storage_path: string | null }) => p.storage_path).filter(
    (p: string | null): p is string => !!p,
  );

  // Si falla el borrado en Storage no se tocan las filas -- mejor reintentar
  // en la próxima pasada que marcar como purgado un archivo que sigue vivo.
  const { error: removeErr } = await admin.storage.from("verified-photos").remove(paths);
  if (removeErr) throw removeErr;

  const { error: updateErr } = await admin
    .from("verified_photos")
    .update({ storage_path: null })
    .in("id", photos.map((p: { id: string }) => p.id));
  if (updateErr) throw updateErr;

  return photos.length;
}

/** Higiene de datos: refleja en el status el vencimiento por tiempo que resolveActiveSession ya aplica en runtime. */
async function expireStaleSessions(admin: ReturnType<typeof supabaseAdmin>, nowIso: string): Promise<number> {
  const { data, error } = await admin
    .from("photo_sessions")
    .update({ status: "expired" })
    .eq("status", "active")
    .lt("expires_at", nowIso)
    .select("id");
  if (error) throw error;
  return data?.length ?? 0;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
