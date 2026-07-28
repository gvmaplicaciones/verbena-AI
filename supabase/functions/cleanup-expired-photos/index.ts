// cleanup-expired-photos
//
// Job periódico (pg_cron -> pg_net, o cualquier scheduler externo) que:
//   1. Purga del bucket 'verified-photos' las fotos efímeras (is_persisted=false,
//      de usuarios sin suscripción activa) cuya expires_at ya venció. Nunca
//      borra la fila de verified_photos -- solo el archivo -- para no romper el
//      historial de photo_sessions/generations que la referencian.
//   2. Borra las generaciones completadas no-favoritas que quedan fuera de las
//      30 más recientes por usuario (Storage + fila en `generations`).
//   3. Expira sesiones activas cuyo expires_at venció (higiene de datos).
//
// Auth: no es un JWT de usuario -- protegida por un secreto compartido que
// solo conoce el scheduler, comparado contra CRON_SECRET.
//
// Request:  POST, Authorization: Bearer <CRON_SECRET>
// Response: { purgedPhotos, expiredSessions, deletedGenerations }

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
    const deletedGenerations = await cleanupOldGenerations(admin);
    return json({ purgedPhotos, expiredSessions, deletedGenerations });
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

/**
 * Borra las generaciones completadas no-favoritas que quedan fuera de las 30
 * más recientes por usuario. Los BATCH_SIZE registros se cargan ordenados por
 * usuario y fecha descendente; en memoria se agrupan por user_id y se retienen
 * los primeros 30 de cada grupo. El resto (posición ≥30) se elimina de Storage
 * y de la base de datos.
 */
async function cleanupOldGenerations(admin: ReturnType<typeof supabaseAdmin>): Promise<number> {
  const { data: gens, error } = await admin
    .from("generations")
    .select("id, user_id, result_storage_path")
    .eq("status", "completed")
    .eq("is_favorite", false)
    .not("result_storage_path", "is", null)
    .order("user_id", { ascending: true })
    .order("created_at", { ascending: false })
    .limit(BATCH_SIZE);
  if (error) throw error;
  if (!gens || gens.length === 0) return 0;

  type GenRow = { id: string; user_id: string; result_storage_path: string };
  const toDelete: GenRow[] = [];
  const countByUser = new Map<string, number>();
  for (const gen of gens as GenRow[]) {
    const count = countByUser.get(gen.user_id) ?? 0;
    countByUser.set(gen.user_id, count + 1);
    if (count >= 30) toDelete.push(gen);
  }

  if (toDelete.length === 0) return 0;

  const paths = toDelete.map((g) => g.result_storage_path);
  const { error: removeErr } = await admin.storage.from("generation-results").remove(paths);
  if (removeErr) throw removeErr;

  const ids = toDelete.map((g) => g.id);
  const { error: deleteErr } = await admin.from("generations").delete().in("id", ids);
  if (deleteErr) throw deleteErr;

  return toDelete.length;
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
