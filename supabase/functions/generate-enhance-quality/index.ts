// generate-enhance-quality
//
// Modo "Mejorar calidad": mejora la nitidez y restaura la cara con
// tencentarc/gfpgan v1.4, scale 2 (ver _shared/replicate.ts). Sin
// verificación de contenido -- este modo no sintetiza contenido nuevo, solo
// mejora la foto de entrada. Salida JPEG normal, sin canal alfa.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { photoBase64: string }          ← foto nueva (data URI)
//                    | { photoSessionId: string }        ← "Otra vez" (ya guardada)
//
// Response: { status: 'completed', generationId, resultUrl }
//        o: { error } con 400/402/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runEnhanceQuality } from "../_shared/replicate.ts";
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
        mode: "enhance_quality",
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
      const result = await runEnhanceQuality(personDataUri);

      const resultRes = await fetch(result.outputUrl);
      if (!resultRes.ok) {
        throw new Error(`failed to download generation result: ${resultRes.status}`);
      }
      const resultBytes = new Uint8Array(await resultRes.arrayBuffer());
      const resultContentType = resultRes.headers.get("Content-Type") ?? "image/jpeg";

      const ext = resultContentType.includes("png") ? "png" : "jpg";
      const resultStoragePath = `${user.id}/${generation.id}.${ext}`;
      const { error: uploadErr } = await admin.storage
        .from("generation-results")
        .upload(resultStoragePath, resultBytes, { contentType: resultContentType, upsert: true });
      if (uploadErr) throw uploadErr;

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
        console.error("generate-enhance-quality: failed to persist completed status", completeUpdateErr);
      }

      return json({ status: "completed", generationId: generation.id, resultUrl: signed.signedUrl });
    } catch (err) {
      console.error("generate-enhance-quality generation error", err);
      await refundCredit(admin, generation.id);
      await admin
        .from("generations")
        .update({ status: "failed", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({ error: "internal error generating image" }, 502);
    }
  } catch (err) {
    console.error("generate-enhance-quality error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
