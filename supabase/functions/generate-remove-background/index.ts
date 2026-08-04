// generate-remove-background
//
// Modo "Eliminar fondo": quita el fondo de una foto con bria/remove-background
// (ver _shared/replicate.ts). Sin verificación de contenido -- este modo no
// sintetiza contenido nuevo, solo quita el fondo. El resultado preserva el
// canal alfa y se guarda/sirve SIEMPRE como PNG.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { photoBase64: string }          ← foto nueva (data URI)
//                    | { photoSessionId: string }        ← "Otra vez" (ya guardada)
//
// Response: { status: 'completed', generationId, resultUrl }
//        o: { error } con 400/402/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runRemoveBackground } from "../_shared/replicate.ts";
import { downloadAsDataUri, resolveActiveSession } from "../_shared/storage.ts";
import { deductCredit, InsufficientCreditsError, refundCredit } from "../_shared/credits.ts";

const RESULT_URL_TTL_SECONDS = 60 * 60;

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

  let body: { photoBase64?: unknown; photoSessionId?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const admin = supabaseAdmin();

  let personDataUri: string;
  let photoSessionId: string | null = null;

  if (typeof body.photoBase64 === "string") {
    personDataUri = body.photoBase64;
  } else if (typeof body.photoSessionId === "string") {
    photoSessionId = body.photoSessionId;
    const resolvedPhoto = await resolveActiveSession(admin, user.id, photoSessionId);
    if (!resolvedPhoto) {
      return json({ error: "invalid or expired photo session" }, 400);
    }
    personDataUri = await downloadAsDataUri(admin, "verified-photos", resolvedPhoto.storagePath);
  } else {
    return json({ error: "photoBase64 or photoSessionId is required" }, 400);
  }

  try {
    const { data: generation, error: genErr } = await admin
      .from("generations")
      .insert({
        user_id: user.id,
        mode: "remove_background",
        photo_session_id: photoSessionId,
        status: "pending",
      })
      .select("id")
      .single();
    if (genErr) throw genErr;

    try {
      await deductCredit(admin, user.id, generation.id, true);
    } catch (err) {
      if (err instanceof InsufficientCreditsError) {
        await admin.from("generations").update({ status: "failed" }).eq("id", generation.id);
        return json({ error: "insufficient_credits" }, 402);
      }
      throw err;
    }

    await admin.from("generations").update({ status: "generating" }).eq("id", generation.id);

    try {
      const result = await runRemoveBackground(personDataUri);

      const resultRes = await fetch(result.outputUrl);
      if (!resultRes.ok) {
        throw new Error(`failed to download generation result: ${resultRes.status}`);
      }
      const resultBytes = new Uint8Array(await resultRes.arrayBuffer());
      // bria/remove-background devuelve PNG con canal alfa.
      const resultContentType = resultRes.headers.get("Content-Type") ?? "image/png";

      const resultStoragePath = `${user.id}/${generation.id}.png`;
      const { error: uploadErr } = await admin.storage
        .from("generation-results")
        .upload(resultStoragePath, resultBytes, { contentType: resultContentType, upsert: true });
      if (uploadErr) throw uploadErr;

      // Persistir result_storage_path en cuanto la subida a Storage tiene
      // éxito -- si algo falla después (signed URL, etc.) la fila ya
      // referencia el archivo real y los 3 mecanismos de limpieza (borrado
      // de cuenta, borrado individual, cron) pueden encontrarlo. Incidente
      // 2026-08-04: archivos huérfanos en Storage sin fila que los
      // referenciara, por guardar result_storage_path solo al completar.
      const { error: pathErr } = await admin
        .from("generations")
        .update({ result_storage_path: resultStoragePath })
        .eq("id", generation.id);
      if (pathErr) throw pathErr;

      const { data: signed, error: signedErr } = await admin.storage
        .from("generation-results")
        .createSignedUrl(resultStoragePath, RESULT_URL_TTL_SECONDS);
      if (signedErr) throw signedErr;

      const { error: completeUpdateErr } = await admin
        .from("generations")
        .update({
          status: "completed",
          replicate_prediction_id: result.predictionId,
          result_storage_path: resultStoragePath,
          completed_at: new Date().toISOString(),
        })
        .eq("id", generation.id);
      if (completeUpdateErr) {
        console.error("generate-remove-background: failed to persist completed status", completeUpdateErr);
      }

      return json({ status: "completed", generationId: generation.id, resultUrl: signed.signedUrl });
    } catch (err) {
      console.error("generate-remove-background generation error", err);
      await refundCredit(admin, generation.id);
      await admin
        .from("generations")
        .update({ status: "failed", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({ error: "internal error generating image" }, 502);
    }
  } catch (err) {
    console.error("generate-remove-background error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
