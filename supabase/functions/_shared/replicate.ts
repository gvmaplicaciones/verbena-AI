const REPLICATE_API_TOKEN = Deno.env.get("REPLICATE_API_TOKEN")!;

// Deployment dedicado (min_instances=0, L40S) creado para sacar
// flux-content-filter de la cola pública compartida de Replicate -- mismo
// modelo, instancia propia. "owner/deployment-name", nunca "owner/model".
const CONTENT_FILTER_DEPLOYMENT =
  Deno.env.get("REPLICATE_CONTENT_FILTER_DEPLOYMENT") ??
  "adlocalia/content-verbenai";

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

// Techo bajo a propósito: la petición que se reintenta (crear predicción o
// consultar su estado) responde rápido incluso cuando Replicate está
// saturado, así que 3 reintentos + backoff no deja al usuario esperando
// mucho más en la pantalla de Processing. El backoff real (~1s/2s/4s) casi
// nunca llega a agotar el presupuesto de 20s.
const RATE_LIMIT_MAX_RETRIES = 3;
const RATE_LIMIT_BASE_DELAY_MS = 1000;
const RATE_LIMIT_BUDGET_MS = 20_000;

// Backoff exponencial (~1s, ~2s, ~4s...) con jitter del 75%-125% para que
// varias llamadas en curso en paralelo (p.ej. content-filter y
// glasses-check en verify-photo) no reintenten todas en el mismo instante.
function backoffDelayMs(attempt: number): number {
  const base = RATE_LIMIT_BASE_DELAY_MS * 2 ** attempt;
  return base * (0.75 + Math.random() * 0.5);
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
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
  let prediction: Prediction = await withRateLimitRetry(
    () => createPrediction(url, body, waitSeconds, label),
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

/** Reintenta `fn` solo si falla con ReplicateRateLimitError -- cualquier otro error se propaga sin tocar. */
async function withRateLimitRetry<T>(fn: () => Promise<T>, label: string): Promise<T> {
  const startedAt = Date.now();
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (!(err instanceof ReplicateRateLimitError)) throw err;
      if (attempt >= RATE_LIMIT_MAX_RETRIES || Date.now() - startedAt >= RATE_LIMIT_BUDGET_MS) {
        throw err;
      }
      const delay = backoffDelayMs(attempt);
      console.warn(`${label}: saturado, reintento ${attempt + 1}/${RATE_LIMIT_MAX_RETRIES} en ${Math.round(delay)}ms`);
      await sleep(delay);
    }
  }
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
      if (rateLimitAttempt >= RATE_LIMIT_MAX_RETRIES || Date.now() - started >= RATE_LIMIT_BUDGET_MS) {
        throw new ReplicateRateLimitError(`Replicate rate limited polling prediction ${id} (${model})`);
      }
      const delay = backoffDelayMs(rateLimitAttempt);
      console.warn(
        `poll ${model}: saturado, reintento ${rateLimitAttempt + 1}/${RATE_LIMIT_MAX_RETRIES} en ${Math.round(delay)}ms`,
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
