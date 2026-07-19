const REPLICATE_API_TOKEN = Deno.env.get("REPLICATE_API_TOKEN")!;

// Identificador confirmado en Replicate. Se deja configurable por env var
// para no tener que redeploy-ear si el owner cambia el slug del modelo.
const CONTENT_FILTER_MODEL =
  Deno.env.get("REPLICATE_CONTENT_FILTER_MODEL") ??
  "lucataco/flux-content-filter";

// cdingram/face-swap: modo Catálogo, cara del usuario sobre la escena de la
// plantilla (confirmado con output real: input_image=plantilla,
// swap_image=foto del usuario). No es modelo oficial de Replicate, así que
// conviene fijarlo a un version hash exacto vía REPLICATE_FACE_SWAP_MODEL
// (formato "cdingram/face-swap:<hash>") para que un cambio futuro del autor
// no altere el comportamiento sin que lo decidamos nosotros -- pendiente:
// aún no se ha fijado en este entorno porque no hay forma de confirmar el
// hash con una predicción real (falta REPLICATE_API_TOKEN de prueba).
// black-forest-labs/flux-kontext-pro: modo Libertad, edición por
// instrucciones sobre la foto del usuario -- modelo oficial de Replicate,
// no necesita version hash.
const FACE_SWAP_MODEL = Deno.env.get("REPLICATE_FACE_SWAP_MODEL") ?? "cdingram/face-swap";
const IMAGE_EDIT_MODEL =
  Deno.env.get("REPLICATE_IMAGE_EDIT_MODEL") ?? "black-forest-labs/flux-kontext-pro";
// Generación de plantillas desde cero (solo admin, generate-template-asset).
const TEXT_TO_IMAGE_MODELS: Record<string, string> = {
  "flux-1.1-pro": Deno.env.get("REPLICATE_FLUX_PRO_MODEL") ?? "black-forest-labs/flux-1.1-pro",
  "flux-dev": Deno.env.get("REPLICATE_FLUX_DEV_MODEL") ?? "black-forest-labs/flux-dev",
};

export interface ContentFilterResult {
  passed: boolean;
  raw: unknown;
  reason?: string;
}

export interface GenerationResult {
  predictionId: string;
  outputUrl: string;
  raw: unknown;
}

/**
 * Runs the moderation model against an image (and, for modo Libertad,
 * optionally the free-text prompt in the same call — confirmed the model
 * accepts both inputs at once, no separate text-moderation service needed).
 */
export async function runContentFilter(
  imageDataUri: string,
  promptText?: string,
): Promise<ContentFilterResult> {
  const input: Record<string, unknown> = { image: imageDataUri };
  if (promptText) input.prompt = promptText;

  // Espera síncrona hasta 30s -- la moderación es rápida y barata ($0,0042);
  // si no da tiempo, cae a "processing" y se resuelve por polling.
  const prediction = await runPrediction(CONTENT_FILTER_MODEL, input, 30);

  // Forma de salida exacta pendiente de confirmar contra el modelo real;
  // se asume un objeto con flags booleanas de NSFW / figura pública / copyright.
  const output = prediction.output as
    | { nsfw?: boolean; public_figure?: boolean; copyright?: boolean }
    | undefined;

  const flagged = !!(output?.nsfw || output?.public_figure || output?.copyright);

  return {
    passed: !flagged,
    raw: prediction.output,
    reason: flagged
      ? [
          output?.nsfw && "contenido NSFW",
          output?.public_figure && "figura pública detectada",
          output?.copyright && "posible infracción de copyright",
        ].filter(Boolean).join(", ")
      : undefined,
  };
}

/** Modo Catálogo: coloca la cara de `userPhotoDataUri` sobre la escena de `templateDataUri`. */
export async function runFaceSwap(
  templateDataUri: string,
  userPhotoDataUri: string,
): Promise<GenerationResult> {
  const prediction = await runPrediction(FACE_SWAP_MODEL, {
    input_image: templateDataUri,
    swap_image: userPhotoDataUri,
  }, 60);
  return toGenerationResult(prediction);
}

/** Modo Libertad: edita `userPhotoDataUri` siguiendo `promptText` en texto libre. */
export async function runImageEdit(
  userPhotoDataUri: string,
  promptText: string,
): Promise<GenerationResult> {
  const prediction = await runPrediction(IMAGE_EDIT_MODEL, {
    input_image: userPhotoDataUri,
    prompt: promptText,
    // La imagen editada debe conservar el encuadre de la foto del usuario,
    // nunca recortarse/estirarse a un aspect ratio fijo del modelo.
    aspect_ratio: "match_input_image",
    // Fijado explícitamente en vez de heredar el default sin examinar
    // (valor de partida, ajustable si el catálogo de prompts lo requiere).
    safety_tolerance: 2,
  }, 60);
  return toGenerationResult(prediction);
}

/**
 * Modo admin (generate-template-asset): genera una escena desde cero a partir
 * de un prompt de texto, sin foto de entrada -- se usa para poblar la tabla
 * `templates` una vez por escena, nunca en el flujo de un usuario final.
 */
export async function runTextToImage(
  promptText: string,
  replicateModel: "flux-1.1-pro" | "flux-dev",
): Promise<GenerationResult> {
  const model = TEXT_TO_IMAGE_MODELS[replicateModel];
  const prediction = await runPrediction(model, {
    prompt: promptText,
    aspect_ratio: "3:4",
    output_format: "jpg",
    safety_tolerance: 2,
  }, 60);
  return toGenerationResult(prediction);
}

function toGenerationResult(prediction: Prediction): GenerationResult {
  // Algunos modelos de Replicate devuelven un string, otros un array con un
  // único elemento -- se normaliza aquí, pendiente de confirmar la forma
  // exacta contra cada modelo real antes de producción.
  const output = prediction.output;
  const outputUrl = Array.isArray(output) ? output[0] : output;
  if (typeof outputUrl !== "string") {
    throw new Error(`unexpected Replicate output shape: ${JSON.stringify(output)}`);
  }
  return { predictionId: prediction.id, outputUrl, raw: output };
}

interface Prediction {
  id: string;
  status: string;
  output: unknown;
  error: unknown;
}

async function runPrediction(
  model: string,
  input: Record<string, unknown>,
  waitSeconds: number,
): Promise<Prediction> {
  // Dos formas posibles de identificar el modelo:
  // "owner/name" (siempre la última versión) -> endpoint /v1/models/{model}/predictions
  // "owner/name:version_hash" (versión fijada) -> endpoint clásico /v1/predictions
  // con el hash en el body, ya que el endpoint /v1/models no acepta version pin.
  const [ownerName, versionHash] = model.split(":");
  const url = versionHash
    ? "https://api.replicate.com/v1/predictions"
    : `https://api.replicate.com/v1/models/${ownerName}/predictions`;
  const body = versionHash ? { version: versionHash, input } : { input };

  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${REPLICATE_API_TOKEN}`,
      "Content-Type": "application/json",
      Prefer: `wait=${waitSeconds}`,
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    throw new Error(`Replicate request failed (${model}): ${res.status} ${await res.text()}`);
  }

  let prediction: Prediction = await res.json();

  if (prediction.status !== "succeeded" && prediction.status !== "failed") {
    prediction = await pollPrediction(prediction.id);
  }

  if (prediction.status === "failed") {
    throw new Error(`Replicate prediction failed (${model}): ${JSON.stringify(prediction.error)}`);
  }

  return prediction;
}

async function pollPrediction(id: string, timeoutMs = 60_000): Promise<Prediction> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const res = await fetch(`https://api.replicate.com/v1/predictions/${id}`, {
      headers: { Authorization: `Bearer ${REPLICATE_API_TOKEN}` },
    });
    const prediction: Prediction = await res.json();
    if (prediction.status === "succeeded" || prediction.status === "failed") {
      return prediction;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`Replicate prediction ${id} timed out`);
}
