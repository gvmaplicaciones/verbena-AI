// generate-catalog
//
// Modo Catálogo: face-swap de la foto verificada del usuario sobre la escena
// de una plantilla fija. Requiere una photo_session activa (creada por
// verify-photo) -- nunca confía en un verifiedPhotoId que mande el cliente
// directamente. Descuenta 1 crédito (gratis -> tier -> extra) SOLO tras
// confirmar sesión + plantilla válidas, y lo reembolsa si Replicate falla
// después de haber cobrado.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { templateId: string, photoSessionId: string }
//
// Response: { status: 'completed', generationId, resultUrl }
//        o: { error } con 400/402/404/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { runFaceSwap } from "../_shared/replicate.ts";
import { downloadAsDataUri, resolveActiveSession, uploadResultImage } from "../_shared/storage.ts";
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

  let body: { templateId?: unknown; photoSessionId?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const templateId = body.templateId;
  const photoSessionId = body.photoSessionId;
  if (typeof templateId !== "string" || typeof photoSessionId !== "string") {
    return json({ error: "templateId and photoSessionId are required" }, 400);
  }

  const admin = supabaseAdmin();

  try {
    const resolvedPhoto = await resolveActiveSession(admin, user.id, photoSessionId);
    if (!resolvedPhoto) {
      return json({ error: "invalid or expired photo session, verify the photo again" }, 400);
    }

    const { data: template, error: templateErr } = await admin
      .from("templates")
      .select("id, image_storage_path")
      .eq("id", templateId)
      .eq("is_active", true)
      .maybeSingle();
    if (templateErr) throw templateErr;
    if (!template) {
      return json({ error: "template not found" }, 404);
    }

    const { data: generation, error: genErr } = await admin
      .from("generations")
      .insert({
        user_id: user.id,
        mode: "catalog",
        template_id: template.id,
        photo_session_id: photoSessionId,
        status: "pending",
      })
      .select("id")
      .single();
    if (genErr) throw genErr;

    try {
      // Solo Catálogo puede usar el crédito gratis (regla de negocio).
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
      const [templateDataUri, photoDataUri] = await Promise.all([
        downloadAsDataUri(admin, "templates", template.image_storage_path),
        downloadAsDataUri(admin, "verified-photos", resolvedPhoto.storagePath),
      ]);

      const result = await runFaceSwap(templateDataUri, photoDataUri);

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
      console.error("generate-catalog generation error", err);
      await refundCredit(admin, generation.id);
      await admin
        .from("generations")
        .update({ status: "failed", completed_at: new Date().toISOString() })
        .eq("id", generation.id);
      return json({ error: "internal error generating image" }, 502);
    }
  } catch (err) {
    console.error("generate-catalog error", err);
    return json({ error: "internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
