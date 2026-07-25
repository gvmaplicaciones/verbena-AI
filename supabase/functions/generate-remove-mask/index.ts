// generate-remove-mask
//
// Modo "Eliminar algo" sub-modo máscara: el usuario pintó sobre la foto las
// zonas a eliminar (blanco = borrar, negro = conservar) y el cliente manda
// esa máscara codificada en base64. El backend descarga la foto verificada
// de Storage, llama a flux-fill-pro con imagen + máscara + prompt fijo, y
// re-verifica el resultado (NSFW + Rekognition) igual que el resto de modos.
// No hay prompt del usuario: la intención ya está en la máscara pintada.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { photoSessionId: string, maskBase64: string }
//           maskBase64: PNG de la máscara sin prefijo data URI, codificado
//           en base64 estándar. Blanco = zona a eliminar, negro = conservar.
//
// Response: { status: 'completed', generationId, resultUrl }
//        o: { status: 'rejected', generationId, reason }
//        o: { error } con 400/402/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runMaskRemoval, runNsfwCheck } from "../_shared/replicate.ts";
import { runCelebrityCheck } from "../_shared/aws.ts";
import { encodeBase64 } from "../_shared/bytes.ts";
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

  let body: { photoSessionId?: unknown; maskBase64?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const photoSessionId = body.photoSessionId;
  const maskBase64 = body.maskBase64;

  if (typeof photoSessionId !== "string") {
    return json({ error: "photoSessionId is required" }, 400);
  }
  if (typeof maskBase64 !== "string" || maskBase64.length === 0) {
    return json({ error: "maskBase64 is required" }, 400);
  }

  const maskDataUri = `data:image/png;base64,${maskBase64}`;
  const admin = supabaseAdmin();

  try {
    const resolvedPhoto = await resolveActiveSession(admin, user.id, photoSessionId);
    if (!resolvedPhoto) {
      return json({ error: "invalid or expired photo session, verify the photo again" }, 400);
    }

    const { data: generation, error: genErr } = await admin
      .from("generations")
      .insert({
        user_id: user.id,
        mode: "remove_mask",
        photo_session_id: photoSessionId,
        status: "pending",
      })
      .select("id")
      .single();
    if (genErr) throw genErr;

    const photoDataUri = await downloadAsDataUri(admin, "verified-photos", resolvedPhoto.storagePath);

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
      const result = await runMaskRemoval(photoDataUri, maskDataUri);

      const resultRes = await fetch(result.outputUrl);
      if (!resultRes.ok) {
        throw new Error(`failed to download generation result: ${resultRes.status}`);
      }
      const resultBytes = new Uint8Array(await resultRes.arrayBuffer());
      const resultContentType = resultRes.headers.get("Content-Type") ?? "image/jpeg";
      const resultDataUri = `data:${resultContentType};base64,${encodeBase64(resultBytes)}`;

      const [isNsfw, celebrityResult] = await Promise.all([
        runNsfwCheck(resultDataUri),
        runCelebrityCheck(resultBytes),
      ]);

      if (isNsfw || celebrityResult.detected) {
        await refundCredit(admin, generation.id);
        await admin
          .from("generations")
          .update({
            status: "rejected",
            moderation_result: { nsfw: isNsfw, celebrity: celebrityResult.raw },
            completed_at: new Date().toISOString(),
          })
          .eq("id", generation.id);
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

      const { data: signed, error: signedErr } = await admin.storage
        .from("generation-results")
        .createSignedUrl(resultStoragePath, RESULT_URL_TTL_SECONDS);
      if (signedErr) throw signedErr;

      await admin
        .from("generations")
        .update({
          status: "completed",
          replicate_prediction_id: result.predictionId,
          result_storage_path: resultStoragePath,
          moderation_result: { nsfw: isNsfw, celebrity: celebrityResult.raw },
          completed_at: new Date().toISOString(),
        })
        .eq("id", generation.id);

      return json({ status: "completed", generationId: generation.id, resultUrl: signed.signedUrl });
    } catch (err) {
      console.error("generate-remove-mask generation error", err);
      await refundCredit(admin, generation.id);
      await admin
        .from("generations")
        .update({ status: "failed", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({ error: "internal error generating image" }, 502);
    }
  } catch (err) {
    console.error("generate-remove-mask error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
