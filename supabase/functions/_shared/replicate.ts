import { backoffDelayMs, RETRY_BUDGET_MS, RETRY_MAX_ATTEMPTS, sleep, withRetry } from "./retry.ts";

const REPLICATE_API_TOKEN = Deno.env.get("REPLICATE_API_TOKEN")!;

// DEPRECATED desde que runNsfwCheck (falcons-ai/nsfw_image_detection) +
// runCelebrityCheck (AWS Rekognition, ver _shared/aws.ts) sustituyeron el
// NSFW y las figuras públicas de este deployment -- runContentFilter ya no
// se llama desde verify-photo. Se deja sin usar a propósito (código y
// deployment) por si hace falta volver atrás, no borrar sin decisión
// explícita.
const CONTENT_FILTER_DEPLOYMENT =
  Deno.env.get("REPLICATE_CONTENT_FILTER_DEPLOYMENT") ??
  "adlocalia/content-verbenai";

// Confirmado con una predicción real (ver memoria de proyecto): input
// {image: dataUri}, output un string plano "normal" | "nsfw" -- sin envolver
// en array ni objeto, a diferencia de flux-content-filter.
const NSFW_MODEL = Deno.env.get("REPLICATE_NSFW_MODEL") ?? "falcons-ai/nsfw_image_detection";

// cdingram/face-swap: modo Catálogo, cara del usuario sobre la escena de la
// plantilla (confirmado con output real: input_image=plantilla,
// swap_image=foto del usuario). No es modelo oficial de Replicate, así que
// conviene fijarlo a un version hash exacto vía REPLICATE_FACE_SWAP_MODEL
// (formato "cdingram/face-swap:<hash>") para que un cambio futuro del autor
// no altere el comportamiento sin que lo decidamos nosotros -- pendiente:
// aún no se ha fijado en este entorno porque no hay forma de confirmar el
// hash con una predicción real (falta REPLICATE_API_TOKEN de prueba).
// openai/gpt-image-2: modo Libertad, edición por instrucciones sobre 1-2
// fotos de referencia del usuario -- modelo oficial de Replicate, no
// necesita version hash. Sustituye a flux-kontext-pro (confirmado con una
// predicción real: input_images es array, quality/output_format/
// aspect_ratio/background/moderation son los parámetros reales, no
// safety_tolerance ni aspect_ratio "match_input_image" que usaba
// flux-kontext-pro). Confirmado en la documentación de OpenAI
// (developers.openai.com/api/docs/guides/image-generation) que el coste sube
// con cada imagen de referencia adicional (siempre se procesan a alta
// fidelidad) -- no afecta al crédito que se cobra al usuario, que sigue
// fijo en 1 sin importar el número de fotos.
const FACE_SWAP_MODEL = Deno.env.get("REPLICATE_FACE_SWAP_MODEL") ?? "cdingram/face-swap";
const IMAGE_EDIT_MODEL =
  Deno.env.get("REPLICATE_IMAGE_EDIT_MODEL") ?? "openai/gpt-image-2";
// Generación de plantillas desde cero (solo admin, generate-template-asset).
const TEXT_TO_IMAGE_MODELS: Record<string, string> = {
  "flux-1.1-pro": Deno.env.get("REPLICATE_FLUX_PRO_MODEL") ?? "black-forest-labs/flux-1.1-pro",
  "flux-dev": Deno.env.get("REPLICATE_FLUX_DEV_MODEL") ?? "black-forest-labs/flux-dev",
};
// VLM ligero para el warning no bloqueante de gafas (el face swap da peor
// resultado si la foto del usuario lleva gafas y la plantilla no). No es
// modelo oficial de Replicate -- pinneado por hash confirmado con una
// predicción real (ver runGlassesCheck), igual que FACE_SWAP_MODEL.
const GLASSES_MODEL =
  Deno.env.get("REPLICATE_GLASSES_MODEL") ??
  "lucataco/moondream2:72ccb656353c348c1385df54b237eeb7bfa874bf11486cf0b9473e691b662d31";

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

  // Espera síncrona hasta 60s (máximo que admite Replicate) -- la cuenta
  // tiene poco crédito y Replicate a veces mete la predicción en cola varios
  // minutos antes de arrancarla, así que conviene apurar el máximo aquí y
  // dejar el resto del margen al polling en pollPrediction().
  const prediction = await runDeploymentPrediction(CONTENT_FILTER_DEPLOYMENT, input, 60);

  // Forma de salida confirmada con una llamada real de prueba (ver commit):
  // nsfw_detected / public_figures / copyright_concerns, no nsfw /
  // public_figure / copyright como se asumía antes -- con los nombres viejos
  // `flagged` daba siempre false y el filtro nunca rechazaba nada.
  const output = prediction.output as
    | { nsfw_detected?: boolean; public_figures?: boolean; copyright_concerns?: boolean }
    | undefined;

  const flagged = !!(output?.nsfw_detected || output?.public_figures || output?.copyright_concerns);

  return {
    passed: !flagged,
    raw: prediction.output,
    reason: flagged
      ? [
          output?.nsfw_detected && "contenido NSFW",
          output?.public_figures && "figura pública detectada",
          output?.copyright_concerns && "posible infracción de copyright",
        ].filter(Boolean).join(", ")
      : undefined,
  };
}

/**
 * NSFW check dedicado (falcons-ai/nsfw_image_detection) -- sustituye la
 * parte nsfw_detected de runContentFilter/flux-content-filter. Se ejecuta en
 * paralelo con runCelebrityCheck (Rekognition) y runGlassesCheck en
 * verify-photo, no de forma secuencial.
 */
export async function runNsfwCheck(imageDataUri: string): Promise<boolean> {
  const prediction = await runPrediction(NSFW_MODEL, { image: imageDataUri }, 30);
  return prediction.output === "nsfw";
}

/**
 * Warning no bloqueante: ¿la foto del usuario lleva gafas? Confirmado con
 * una predicción real que moondream2 responde "Yes"/"No" de forma fiable a
 * esta pregunta directa (~0.15-0.5s, coste insignificante frente al face
 * swap). No afecta a `passed` de runContentFilter -- se llama aparte, solo
 * sobre fotos ya aprobadas.
 */
export async function runGlassesCheck(imageDataUri: string): Promise<boolean> {
  const prediction = await runPrediction(GLASSES_MODEL, {
    image: imageDataUri,
    prompt: "Is this person wearing glasses/eyewear? Answer with just yes or no.",
  }, 30);

  // El modelo devuelve el texto troceado en tokens (array de strings) en vez
  // de un string único -- se concatena antes de mirar si empieza por "yes".
  const output = prediction.output;
  const text = (Array.isArray(output) ? output.join("") : String(output ?? "")).trim().toLowerCase();
  return text.startsWith("yes");
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

/**
 * Modo Libertad: edita 1-2 fotos de referencia (`referenceImageDataUris`)
 * siguiendo `promptText` en texto libre. La segunda foto es opcional --
 * gpt-image-2 la usa para el caso "cambia esto por esto otro" (p.ej.
 * combinar dos fotos), no solo para editar una sola.
 */
export async function runImageEdit(
  referenceImageDataUris: string[],
  promptText: string,
): Promise<GenerationResult> {
  const prediction = await runPrediction(IMAGE_EDIT_MODEL, {
    input_images: referenceImageDataUris,
    prompt: promptText,
    quality: "medium",
    output_format: "jpeg",
    // Confirmado con una predicción real que gpt-image-2 acepta "auto" (el
    // readme público solo documenta 1:1/3:2/2:3, pero la llamada real del
    // usuario usó "auto" con éxito) -- deja que el modelo elija el encuadre
    // en vez de forzar uno fijo.
    aspect_ratio: "auto",
    background: "auto",
    moderation: "auto",
    number_of_images: 1,
    output_compression: 90,
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

// Reintento SOLO para saturación de Replicate (429 -- la cuenta con poco
// crédito la sufre a menudo, ver memoria de proyecto). Cualquier otro fallo
// (input inválido, modelo caído, timeout de polling) se propaga tal cual en
// el primer intento -- no hay nada que un reintento arregle ahí y enmascarar
// el error real sería peor.
class ReplicateRateLimitError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ReplicateRateLimitError";
  }
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
  return createAndAwaitPrediction(url, body, waitSeconds, model);
}

/**
 * Deployment dedicado de Replicate ("owner/deployment-name") en vez del
 * modelo público -- misma respuesta, pero corre en la instancia propia del
 * deployment en lugar de la cola pública compartida. La versión del modelo
 * la fija el deployment, no se manda en el body.
 */
async function runDeploymentPrediction(
  deployment: string,
  input: Record<string, unknown>,
  waitSeconds: number,
): Promise<Prediction> {
  const url = `https://api.replicate.com/v1/deployments/${deployment}/predictions`;
  return createAndAwaitPrediction(url, { input }, waitSeconds, `deployment:${deployment}`);
}

async function createAndAwaitPrediction(
  url: string,
  body: Record<string, unknown>,
  waitSeconds: number,
  label: string,
): Promise<Prediction> {
  // La creación aún no existe en Replicate si nos da 429 aquí, así que
  // reintentar desde cero es seguro -- no hay predicción a medias ni coste
  // ya incurrido.
  let prediction: Prediction = await withRetry(
    () => createPrediction(url, body, waitSeconds, label),
    (err) => err instanceof ReplicateRateLimitError,
    `crear predicción (${label})`,
  );

  if (prediction.status !== "succeeded" && prediction.status !== "failed") {
    prediction = await pollPrediction(prediction.id, label);
  }

  if (prediction.status === "failed") {
    throw new Error(`Replicate prediction failed (${label}): ${JSON.stringify(prediction.error)}`);
  }

  return prediction;
}

async function createPrediction(
  url: string,
  body: Record<string, unknown>,
  waitSeconds: number,
  model: string,
): Promise<Prediction> {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${REPLICATE_API_TOKEN}`,
      "Content-Type": "application/json",
      Prefer: `wait=${waitSeconds}`,
    },
    body: JSON.stringify(body),
  });

  if (res.status === 429) {
    throw new ReplicateRateLimitError(`Replicate rate limited creating prediction (${model})`);
  }
  if (!res.ok) {
    throw new Error(`Replicate request failed (${model}): ${res.status} ${await res.text()}`);
  }

  return res.json();
}

// 120s en vez de 60s -- crédito bajo en la cuenta de Replicate mete las
// predicciones en cola varios minutos antes de arrancarlas de forma
// intermitente; con esto el presupuesto total (wait síncrono + polling)
// pasa de ~90-120s a ~180s.
async function pollPrediction(id: string, model: string, timeoutMs = 120_000): Promise<Prediction> {
  const started = Date.now();
  let rateLimitAttempt = 0;
  while (Date.now() - started < timeoutMs) {
    const res = await fetch(`https://api.replicate.com/v1/predictions/${id}`, {
      headers: { Authorization: `Bearer ${REPLICATE_API_TOKEN}` },
    });

    if (res.status === 429) {
      if (rateLimitAttempt >= RETRY_MAX_ATTEMPTS || Date.now() - started >= RETRY_BUDGET_MS) {
        throw new ReplicateRateLimitError(`Replicate rate limited polling prediction ${id} (${model})`);
      }
      const delay = backoffDelayMs(rateLimitAttempt);
      console.warn(
        `poll ${model}: saturado, reintento ${rateLimitAttempt + 1}/${RETRY_MAX_ATTEMPTS} en ${Math.round(delay)}ms`,
      );
      rateLimitAttempt++;
      await sleep(delay);
      continue;
    }
    if (!res.ok) {
      throw new Error(`Replicate poll failed (${model}): ${res.status} ${await res.text()}`);
    }

    const prediction: Prediction = await res.json();
    if (prediction.status === "succeeded" || prediction.status === "failed") {
      return prediction;
    }
    // Reset: el backoff solo debe escalar mientras el 429 se repite seguido,
    // no acumularse durante un polling largo pero sano.
    rateLimitAttempt = 0;
    await sleep(1000);
  }
  throw new Error(`Replicate prediction ${id} timed out`);
}
