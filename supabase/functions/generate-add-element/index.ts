// generate-add-element
//
// Modo "Añadir algo": edita 1-2 fotos verificadas del usuario (gpt-image-2,
// ver _shared/replicate.ts) según un prompt de texto que describe qué
// objeto/prenda/accesorio añadir. La segunda foto es opcional, para el caso
// "cambia esto por esto otro" -- pasa por la MISMA verificación que la
// primera (hash, NSFW, Rekognition), ninguna foto se libra por ser la
// segunda. A diferencia de Catálogo, aquí el RESULTADO de la edición (no las
// fotos de entrada, que ya verificó verify-photo, ni el deployment
// deprecated de Replicate) se comprueba con los mismos modelos que el resto
// del pipeline -- NSFW (falcons-ai/nsfw_image_detection) y figuras públicas
// (AWS Rekognition) -- antes de mostrarlo. El prompt libre puede hacer que
// gpt-image-2 genere algo que las fotos originales no tenían, así que hace
// falta re-comprobar la salida. Si se rechaza, se reembolsa el crédito ya
// descontado. Igual que el resto de modos, puede tirar del único crédito
// gratis disponible por usuario (allowFree = true, regla "cualquier modo").
// No se comprueba copyright (esa parte del filtro antiguo se descarta).
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { promptText: string, photoSessionId: string, secondPhotoSessionId?: string }
//
// Response: { status: 'completed', generationId, resultUrl }
//        o: { status: 'rejected', generationId, reason }
//        o: { error } con 400/402/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runImageEdit, runNsfwCheck, runTextModerationCheck } from "../_shared/replicate.ts";
import { runCelebrityCheck } from "../_shared/aws.ts";
import { encodeBase64 } from "../_shared/bytes.ts";
import { downloadAsDataUri, resolveActiveSession } from "../_shared/storage.ts";
import { deductCredit, InsufficientCreditsError, refundCredit } from "../_shared/credits.ts";

const RESULT_URL_TTL_SECONDS = 60 * 60;
const MAX_PROMPT_LENGTH = 500;

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

  let body: { promptText?: unknown; photoSessionId?: unknown; secondPhotoSessionId?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const promptText = body.promptText;
  const photoSessionId = body.photoSessionId;
  const secondPhotoSessionId = body.secondPhotoSessionId;
  if (
    typeof promptText !== "string" || promptText.trim().length === 0 ||
    promptText.length > MAX_PROMPT_LENGTH
  ) {
    return json({ error: `promptText is required (max ${MAX_PROMPT_LENGTH} chars)` }, 400);
  }
  if (typeof photoSessionId !== "string") {
    return json({ error: "photoSessionId is required" }, 400);
  }
  if (secondPhotoSessionId !== undefined && typeof secondPhotoSessionId !== "string") {
    return json({ error: "secondPhotoSessionId must be a string" }, 400);
  }

  const admin = supabaseAdmin();

  try {
    const resolvedPhoto = await resolveActiveSession(admin, user.id, photoSessionId);
    if (!resolvedPhoto) {
      return json({ error: "invalid or expired photo session, verify the photo again" }, 400);
    }

    let resolvedSecondPhoto: { verifiedPhotoId: string; storagePath: string } | null = null;
    if (typeof secondPhotoSessionId === "string") {
      resolvedSecondPhoto = await resolveActiveSession(admin, user.id, secondPhotoSessionId);
      if (!resolvedSecondPhoto) {
        return json({ error: "invalid or expired second photo session, verify the photo again" }, 400);
      }
    }

    const { data: generation, error: genErr } = await admin
      .from("generations")
      .insert({
        user_id: user.id,
        mode: "add_element",
        prompt_text: promptText,
        photo_session_id: photoSessionId,
        second_photo_session_id: resolvedSecondPhoto ? secondPhotoSessionId : null,
        status: "pending",
      })
      .select("id")
      .single();
    if (genErr) throw genErr;

    // Moderación de texto ANTES de gastar en descarga/generación de imagen --
    // rechaza aquí si el prompt pide incluir a una persona real/famosa/
    // identificable, sin haber tocado aún el crédito del usuario.
    if (await runTextModerationCheck(promptText)) {
      await admin
        .from("generations")
        .update({ status: "rejected", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({
        status: "rejected",
        generationId: generation.id,
        reason: "No se pueden generar imágenes de personas reales, famosas o identificables.",
      });
    }

    const photoDataUri = await downloadAsDataUri(admin, "verified-photos", resolvedPhoto.storagePath);
    const referenceImageDataUris = [photoDataUri];
    if (resolvedSecondPhoto) {
      referenceImageDataUris.push(
        await downloadAsDataUri(admin, "verified-photos", resolvedSecondPhoto.storagePath),
      );
    }

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
      const result = await runImageEdit(referenceImageDataUris, promptText);

      const resultRes = await fetch(result.outputUrl);
      if (!resultRes.ok) {
        throw new Error(`failed to download generation result: ${resultRes.status}`);
      }
      const resultBytes = new Uint8Array(await resultRes.arrayBuffer());
      const resultContentType = resultRes.headers.get("Content-Type") ?? "image/jpeg";
      const resultDataUri = `data:${resultContentType};base64,${encodeBase64(resultBytes)}`;

      // El prompt libre puede llevar a gpt-image-2 a generar algo que las
      // fotos de entrada no tenían -- se re-comprueba el resultado con los
      // mismos modelos que verify-photo (NSFW + Rekognition), en paralelo.
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
          console.error("generate-add-element: failed to persist rejected status", rejectUpdateErr);
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
        console.error("generate-add-element: failed to persist completed status", completeUpdateErr);
      }

      return json({ status: "completed", generationId: generation.id, resultUrl: signed.signedUrl });
    } catch (err) {
      console.error("generate-add-element generation error", err);
      await refundCredit(admin, generation.id);
      await admin
        .from("generations")
        .update({ status: "failed", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({ error: "internal error generating image" }, 502);
    }
  } catch (err) {
    console.error("generate-add-element error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
