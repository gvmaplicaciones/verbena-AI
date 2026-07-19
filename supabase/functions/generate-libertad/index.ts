// generate-libertad
//
// Modo Libertad: edita la foto verificada del usuario según un prompt de
// texto libre. A diferencia de Catálogo, aquí SIEMPRE se filtra también el
// texto del prompt (mismo modelo de moderación, imagen + texto en una sola
// llamada) antes de descontar crédito -- si el filtro rechaza, no se cobra
// nada y nunca se usa el crédito gratis (ese es exclusivo de Catálogo).
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { promptText: string, photoSessionId: string }
//
// Response: { status: 'completed', generationId, resultUrl }
//        o: { status: 'rejected', generationId, reason }
//        o: { error } con 400/402/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runContentFilter, runImageEdit } from "../_shared/replicate.ts";
import { downloadAsDataUri, resolveActiveSession, uploadResultImage } from "../_shared/storage.ts";
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
        mode: "libertad",
        prompt_text: promptText,
        photo_session_id: photoSessionId,
        status: "verifying",
      })
      .select("id")
      .single();
    if (genErr) throw genErr;

    const photoDataUri = await downloadAsDataUri(admin, "verified-photos", resolvedPhoto.storagePath);

    const moderation = await runContentFilter(photoDataUri, promptText);
    if (!moderation.passed) {
      await admin
        .from("generations")
        .update({ status: "rejected", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({
        status: "rejected",
        generationId: generation.id,
        reason: moderation.reason ?? "El prompt no ha pasado la verificación.",
      });
    }

    try {
      // Libertad nunca usa el crédito gratis (regla de negocio): allowFree = false.
      await deductCredit(admin, user.id, generation.id, false);
    } catch (err) {
      if (err instanceof InsufficientCreditsError) {
        await admin.from("generations").update({ status: "failed" }).eq("id", generation.id);
        return json({ error: "insufficient_credits" }, 402);
      }
      throw err;
    }

    await admin.from("generations").update({ status: "generating" }).eq("id", generation.id);

    try {
      const result = await runImageEdit(photoDataUri, promptText);

      const resultStoragePath = `${user.id}/${generation.id}.jpg`;
      await uploadResultImage(admin, "generation-results", resultStoragePath, result.outputUrl);

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
          completed_at: new Date().toISOString(),
        })
        .eq("id", generation.id);

      return json({ status: "completed", generationId: generation.id, resultUrl: signed.signedUrl });
    } catch (err) {
      console.error("generate-libertad generation error", err);
      await refundCredit(admin, generation.id);
      await admin
        .from("generations")
        .update({ status: "failed", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({ error: "internal error generating image" }, 502);
    }
  } catch (err) {
    console.error("generate-libertad error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
