// generate-remove-element
//
// Modo "Eliminar algo" (sub-modo "por texto"): edita 1 foto verificada del
// usuario (gpt-image-2, ver _shared/replicate.ts runElementRemoval) según un
// prompt de texto que describe qué quitar de la foto. A diferencia de
// Añadir algo, aquí solo se admite 1 foto -- no tiene sentido combinar dos
// fotos para quitar algo de una de ellas (ver
// PhotoSelectScreen._maxSelectedImages). Igual que Añadir algo, el
// RESULTADO de la edición se re-verifica (NSFW + Rekognition) antes de
// mostrarlo, porque el prompt libre puede hacer que gpt-image-2 altere algo
// que las fotos originales no tenían -- si se rechaza, se reembolsa el
// crédito ya descontado. Puede tirar del único crédito gratis por usuario
// (allowFree = true, regla "cualquier modo").
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { promptText: string, photoSessionId: string }
//
// Response: { status: 'completed', generationId, resultUrl }
//        o: { status: 'rejected', generationId, reason }
//        o: { error } con 400/402/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runElementRemoval, runNsfwCheck } from "../_shared/replicate.ts";
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

  let body: { promptText?: unknown; photoSessionId?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const promptText = body.promptText;
  const photoSessionId = body.photoSessionId;
  if (
    typeof promptText !== "string" || promptText.trim().length === 0 ||
    promptText.length > MAX_PROMPT_LENGTH
  ) {
    return json({ error: `promptText is required (max ${MAX_PROMPT_LENGTH} chars)` }, 400);
  }
  if (typeof photoSessionId !== "string") {
    return json({ error: "photoSessionId is required" }, 400);
  }

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
        mode: "remove_element",
        prompt_text: promptText,
        photo_session_id: photoSessionId,
        status: "pending",
      })
      .select("id")
      .single();
    if (genErr) throw genErr;

    const photoDataUri = await downloadAsDataUri(admin, "verified-photos", resolvedPhoto.storagePath);

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
      const result = await runElementRemoval(photoDataUri, promptText);

      const resultRes = await fetch(result.outputUrl);
      if (!resultRes.ok) {
        throw new Error(`failed to download generation result: ${resultRes.status}`);
      }
      const resultBytes = new Uint8Array(await resultRes.arrayBuffer());
      const resultContentType = resultRes.headers.get("Content-Type") ?? "image/jpeg";
      const resultDataUri = `data:${resultContentType};base64,${encodeBase64(resultBytes)}`;

      // El prompt libre puede llevar a gpt-image-2 a alterar algo que la
      // foto de entrada no tenía -- se re-comprueba el resultado con los
      // mismos modelos que verify-photo (NSFW + Rekognition), en paralelo.
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
      console.error("generate-remove-element generation error", err);
      await refundCredit(admin, generation.id);
      await admin
        .from("generations")
        .update({ status: "failed", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({ error: "internal error generating image" }, 502);
    }
  } catch (err) {
    console.error("generate-remove-element error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
