// generate-catalog
//
// Modo Catálogo: genera sobre la foto verificada del usuario a partir del
// scene_prompt de una plantilla fija (misma arquitectura que generate-
// libertad, ver runCatalogGeneration en _shared/replicate.ts) -- ya no hace
// face-swap sobre la imagen de la plantilla, que se quedó sin calidad
// suficiente tras varias pruebas. Requiere una photo_session activa (creada
// por verify-photo) -- nunca confía en un verifiedPhotoId que mande el
// cliente directamente. Descuenta 1 crédito (gratis -> tier -> extra) SOLO
// tras confirmar sesión + plantilla válidas, y lo reembolsa si Replicate
// falla después de haber cobrado.
//
// Request:  POST, Authorization: Bearer <supabase JWT>
//           body JSON = { templateId: string, photoSessionId: string }
//
// Response: { status: 'completed', generationId, resultUrl }
//        o: { error } con 400/402/404/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { getAuthedUser, supabaseAdmin } from "../_shared/supabase.ts";
import { CatalogTemplateType, runCatalogGeneration } from "../_shared/replicate.ts";
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
      .select("id, scene_prompt, template_type, object_reference_image")
      .eq("id", templateId)
      .eq("is_active", true)
      .maybeSingle();
    if (templateErr) throw templateErr;
    if (!template) {
      return json({ error: "template not found" }, 404);
    }
    // scene_prompt y template_type son obligatorios para construir el prompt
    // de gpt-image-2 -- una plantilla activa sin ellos es un error de
    // configuración del admin, no algo recuperable en runtime.
    if (!template.scene_prompt || !template.template_type) {
      console.error(`generate-catalog: template ${template.id} has no scene_prompt/template_type`);
      return json({ error: "template misconfigured" }, 500);
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
      // El crédito gratis vale en cualquier modo (allowFree=true en todos
      // los generate-*, ver CLAUDE.md).
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
      const [photoDataUri, objectReferenceDataUri] = await Promise.all([
        downloadAsDataUri(admin, "verified-photos", resolvedPhoto.storagePath),
        template.object_reference_image
          ? downloadAsDataUri(admin, "templates", template.object_reference_image)
          : Promise.resolve(null),
      ]);

      const result = await runCatalogGeneration(
        photoDataUri,
        objectReferenceDataUri,
        template.scene_prompt,
        template.template_type as CatalogTemplateType,
      );

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
