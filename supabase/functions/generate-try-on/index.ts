// generate-try-on
//
// Modo "Probar un look" (FASE 5): viste a la persona de una foto verificada
// (photoSessionId) con 1-4 prendas de referencia (prunaai/p-image-try-on, ver
// _shared/replicate.ts). Cada prenda viene de uno de dos orígenes posibles,
// mezclables en la misma llamada:
//   - garmentPhotoSessionIds: subida ad-hoc para esta generación, ya pasó por
//     verify-photo (mismo pipeline genérico que la foto de persona -- hash,
//     NSFW, Rekognition), no se guarda en el Armario.
//   - garmentIds: prenda ya guardada en el Armario (tabla garments), aprobada
//     y persistida en el momento de subirla (ver upload-garment) -- se
//     revalida solo la propiedad aquí, sin volver a moderar.
// TODAS las prendas pasan por moderación en algún punto antes de llegar aquí
// -- ninguna se libra por "ser solo un objeto" (regla de negocio, ver
// CLAUDE.md). El resultado final (persona + prendas combinadas) se
// re-comprueba con NSFW + Rekognition antes de mostrarlo, igual que el resto
// de modos que sintetizan una imagen nueva. 1 crédito fijo, sin importar
// cuántas prendas se combinen.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { photoSessionId: string,
//                          garmentPhotoSessionIds?: string[],
//                          garmentIds?: string[] }
//           1-4 prendas en total entre ambos arrays.
//
// Response: { status: 'completed', generationId, resultUrl }
//        o: { status: 'rejected', generationId, reason }
//        o: { error } con 400/402/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runTryOn, runNsfwCheck } from "../_shared/replicate.ts";
import { runCelebrityCheck } from "../_shared/aws.ts";
import { encodeBase64 } from "../_shared/bytes.ts";
import { downloadAsDataUri, resolveActiveSession } from "../_shared/storage.ts";
import { deductCredit, InsufficientCreditsError, refundCredit } from "../_shared/credits.ts";

const RESULT_URL_TTL_SECONDS = 60 * 60;
const MAX_GARMENTS = 4;

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

  let body: {
    photoSessionId?: unknown;
    garmentPhotoSessionIds?: unknown;
    garmentIds?: unknown;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const photoSessionId = body.photoSessionId;
  if (typeof photoSessionId !== "string") {
    return json({ error: "photoSessionId is required" }, 400);
  }

  const garmentPhotoSessionIds = body.garmentPhotoSessionIds ?? [];
  const garmentIds = body.garmentIds ?? [];
  if (
    !Array.isArray(garmentPhotoSessionIds) ||
    !garmentPhotoSessionIds.every((id) => typeof id === "string") ||
    !Array.isArray(garmentIds) ||
    !garmentIds.every((id) => typeof id === "string")
  ) {
    return json({ error: "garmentPhotoSessionIds and garmentIds must be arrays of strings" }, 400);
  }

  const totalGarments = garmentPhotoSessionIds.length + garmentIds.length;
  if (totalGarments < 1 || totalGarments > MAX_GARMENTS) {
    return json({ error: `must provide between 1 and ${MAX_GARMENTS} garments in total` }, 400);
  }

  const admin = supabaseAdmin();

  try {
    const resolvedPhoto = await resolveActiveSession(admin, user.id, photoSessionId);
    if (!resolvedPhoto) {
      return json({ error: "invalid or expired photo session, verify the photo again" }, 400);
    }

    // Prendas ad-hoc: mismo mecanismo de propiedad/vigencia que la foto de
    // persona -- nunca hay que confiar en un id que mande el cliente sin
    // revalidarlo contra su dueño real.
    const adHocGarmentPaths: string[] = [];
    for (const id of garmentPhotoSessionIds as string[]) {
      const resolved = await resolveActiveSession(admin, user.id, id);
      if (!resolved) {
        return json({ error: `invalid or expired garment photo session '${id}'` }, 400);
      }
      adHocGarmentPaths.push(resolved.storagePath);
    }

    // Prendas del Armario: ya moderadas al subirlas (ver upload-garment), solo
    // se revalida que sigan existiendo y pertenezcan al usuario.
    const wardrobeGarmentPaths: string[] = [];
    for (const id of garmentIds as string[]) {
      const { data: garment, error: garmentErr } = await admin
        .from("garments")
        .select("id, storage_path")
        .eq("id", id)
        .eq("user_id", user.id)
        .maybeSingle();
      if (garmentErr) throw garmentErr;
      if (!garment || !garment.storage_path) {
        return json({ error: `garment '${id}' not found` }, 400);
      }
      wardrobeGarmentPaths.push(garment.storage_path);
    }

    const { data: generation, error: genErr } = await admin
      .from("generations")
      .insert({
        user_id: user.id,
        mode: "try_on",
        photo_session_id: photoSessionId,
        garment_photo_session_ids: garmentPhotoSessionIds.length > 0 ? garmentPhotoSessionIds : null,
        garment_ids: garmentIds.length > 0 ? garmentIds : null,
        status: "pending",
      })
      .select("id")
      .single();
    if (genErr) throw genErr;

    const personDataUri = await downloadAsDataUri(admin, "verified-photos", resolvedPhoto.storagePath);
    const garmentDataUris = await Promise.all([
      ...adHocGarmentPaths.map((path) => downloadAsDataUri(admin, "verified-photos", path)),
      ...wardrobeGarmentPaths.map((path) => downloadAsDataUri(admin, "garments", path)),
    ]);

    try {
      // Cualquier modo puede tirar del único crédito gratis por usuario.
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
      const result = await runTryOn(personDataUri, garmentDataUris);

      const resultRes = await fetch(result.outputUrl);
      if (!resultRes.ok) {
        throw new Error(`failed to download generation result: ${resultRes.status}`);
      }
      const resultBytes = new Uint8Array(await resultRes.arrayBuffer());
      const resultContentType = resultRes.headers.get("Content-Type") ?? "image/jpeg";
      const resultDataUri = `data:${resultContentType};base64,${encodeBase64(resultBytes)}`;

      // El resultado combina persona + prendas en una imagen nueva -- se
      // re-comprueba con los mismos modelos que verify-photo (NSFW +
      // Rekognition), en paralelo, igual que el resto de modos que sintetizan
      // una imagen nueva.
      const [isNsfw, celebrityResult] = await Promise.all([
        runNsfwCheck(resultDataUri),
        runCelebrityCheck(resultBytes),
      ]);

      if (isNsfw || celebrityResult.detected) {
        await refundCredit(admin, generation.id);
        const { error: rejectUpdateErr } = await admin
          .from("generations")
          .update({
            status: "rejected",
            completed_at: new Date().toISOString(),
          })
          .eq("id", generation.id);
        if (rejectUpdateErr) {
          console.error("generate-try-on: failed to persist rejected status", rejectUpdateErr);
        }
        return json({
          status: "rejected",
          generationId: generation.id,
          reason: isNsfw
            ? "El resultado no ha pasado la verificación de contenido."
            : "El resultado no ha pasado la verificación (figura pública detectada).",
        });
      }

      const resultStoragePath = `${user.id}/${generation.id}.jpg`;
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
        console.error("generate-try-on: failed to persist completed status", completeUpdateErr);
      }

      return json({ status: "completed", generationId: generation.id, resultUrl: signed.signedUrl });
    } catch (err) {
      console.error("generate-try-on generation error", err);
      await refundCredit(admin, generation.id);
      await admin
        .from("generations")
        .update({ status: "failed", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({ error: "internal error generating image" }, 502);
    }
  } catch (err) {
    console.error("generate-try-on error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
