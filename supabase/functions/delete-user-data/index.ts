// delete-user-data
//
// Borrado de cuenta ("derecho al olvido"). Borra el usuario de Supabase Auth
// -- por FK on delete cascade eso ya limpia solo user_credits,
// verified_photos, photo_sessions, generations y moderation_appeals.
// credit_transactions es la única tabla que sobrevive a propósito (ver
// migración 20260717000400): se conserva desvinculada (user_id = null) para
// contabilidad/disputas de cobro con Apple/Google, ya no atribuible al
// usuario borrado.
//
// Los archivos en Storage NO cascadean con el borrado de filas -- hay que
// borrarlos explícitamente ANTES de borrar el usuario, mientras aún
// podemos leer sus storage_path.
//
// No toca RevenueCat/la suscripción activa: cancelar el cobro recurrente en
// Apple/Google Play es responsabilidad del usuario o de un flujo aparte,
// fuera del alcance de este borrado de datos.
//
// Solo opera sobre el usuario autenticado (nunca acepta un userId del
// cliente, evita borrar la cuenta de otra persona).
//
// Request:  POST, Authorization: Bearer <supabase JWT>
// Response: { status: 'deleted' }

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

  const admin = supabaseAdmin();

  try {
    await deleteStorageObjects(admin, user.id);

    const { error: deleteErr } = await admin.auth.admin.deleteUser(user.id);
    if (deleteErr) throw deleteErr;

    return json({ status: "deleted" });
  } catch (err) {
    console.error("delete-user-data error", err);
    return json({ error: "internal error deleting account" }, 500);
  }
});

async function deleteStorageObjects(admin: ReturnType<typeof supabaseAdmin>, userId: string): Promise<void> {
  const { data: photos, error: photosErr } = await admin
    .from("verified_photos")
    .select("storage_path")
    .eq("user_id", userId)
    .not("storage_path", "is", null);
  if (photosErr) throw photosErr;

  const photoPaths = (photos ?? [])
    .map((p: { storage_path: string | null }) => p.storage_path)
    .filter((p: string | null): p is string => !!p);
  if (photoPaths.length > 0) {
    const { error } = await admin.storage.from("verified-photos").remove(photoPaths);
    if (error) throw error;
  }

  const { data: generations, error: gensErr } = await admin
    .from("generations")
    .select("result_storage_path")
    .eq("user_id", userId)
    .not("result_storage_path", "is", null);
  if (gensErr) throw gensErr;

  const resultPaths = (generations ?? [])
    .map((g: { result_storage_path: string | null }) => g.result_storage_path)
    .filter((p: string | null): p is string => !!p);
  if (resultPaths.length > 0) {
    const { error } = await admin.storage.from("generation-results").remove(resultPaths);
    if (error) throw error;
  }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
