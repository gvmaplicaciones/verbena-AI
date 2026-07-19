// generate-template-asset
//
// Herramienta de admin (no la usa la app de usuarios finales): genera una
// escena desde cero con flux-1.1-pro/flux-dev a partir de un prompt de
// texto, la sube al bucket privado 'templates' y crea la fila en la tabla
// `templates` con is_active=false, para revisar manualmente antes de
// publicarla. Autenticación: el propio SUPABASE_SERVICE_ROLE_KEY como Bearer
// (no hay un rol de admin en auth.users todavía, y esta function nunca la
// llama el cliente Flutter).
//
// Request:  POST, Authorization: Bearer <service role key>
//           body JSON = { categoryId: string, name: string, prompt: string,
//                          replicateModel?: 'flux-1.1-pro' | 'flux-dev',
//                          sortOrder?: number }
//
// Response: { templateId, imageStoragePath, previewUrl }
//        o: { error } con 400/401/404/502 según el caso.

import { corsHeaders } from "../_shared/cors.ts";
import { supabaseAdmin } from "../_shared/supabase.ts";
import { runTextToImage } from "../_shared/replicate.ts";
import { uploadResultImage } from "../_shared/storage.ts";

const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PREVIEW_URL_TTL_SECONDS = 60 * 60 * 24;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (authHeader !== `Bearer ${SERVICE_ROLE_KEY}`) {
    return json({ error: "unauthorized" }, 401);
  }

  let body: {
    categoryId?: unknown;
    name?: unknown;
    prompt?: unknown;
    replicateModel?: unknown;
    sortOrder?: unknown;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const categoryId = body.categoryId;
  const name = body.name;
  const prompt = body.prompt;
  const replicateModel = body.replicateModel ?? "flux-1.1-pro";
  const sortOrder = typeof body.sortOrder === "number" ? body.sortOrder : 0;

  if (typeof categoryId !== "string" || typeof name !== "string" || typeof prompt !== "string") {
    return json({ error: "categoryId, name and prompt are required" }, 400);
  }
  if (replicateModel !== "flux-1.1-pro" && replicateModel !== "flux-dev") {
    return json({ error: "replicateModel must be 'flux-1.1-pro' or 'flux-dev'" }, 400);
  }

  const admin = supabaseAdmin();

  try {
    const { data: category, error: categoryErr } = await admin
      .from("template_categories")
      .select("id")
      .eq("id", categoryId)
      .maybeSingle();
    if (categoryErr) throw categoryErr;
    if (!category) {
      return json({ error: `unknown categoryId '${categoryId}'` }, 404);
    }

    const result = await runTextToImage(prompt, replicateModel);

    const imageStoragePath = `${categoryId}/${crypto.randomUUID()}.jpg`;
    await uploadResultImage(admin, "templates", imageStoragePath, result.outputUrl);

    const { data: template, error: insertErr } = await admin
      .from("templates")
      .insert({
        category_id: categoryId,
        name,
        image_storage_path: imageStoragePath,
        source_prompt: prompt,
        replicate_model: replicateModel,
        is_active: false,
        sort_order: sortOrder,
      })
      .select("id")
      .single();
    if (insertErr) throw insertErr;

    const { data: signed, error: signedErr } = await admin.storage
      .from("templates")
      .createSignedUrl(imageStoragePath, PREVIEW_URL_TTL_SECONDS);
    if (signedErr) throw signedErr;

    return json({
      templateId: template.id,
      imageStoragePath,
      previewUrl: signed.signedUrl,
    });
  } catch (err) {
    console.error("generate-template-asset error", err);
    return json({ error: "internal error generating template asset" }, 502);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
