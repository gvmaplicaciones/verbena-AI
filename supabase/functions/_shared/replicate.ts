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

// DEPRECATED: cdingram/face-swap no tenía forma de indicar A QUIÉN sustituir
// en plantillas con varias personas (siempre cogía la cara más prominente),
// lo que fallaba en plantillas de grupo. Sustituido por runCatalogFaceSwap
// (gpt-image-2, ver más abajo) -- se deja sin usar a propósito, no borrar sin
// decisión explícita, mismo criterio que CONTENT_FILTER_DEPLOYMENT.
// openai/gpt-image-2: modo Añadir algo, edición por instrucciones sobre 1-2
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
// Modo "Cambiar fondo" (FASE 3): único modo que no usa gpt-image-2 -- Seedream
// da mejor resultado recomponiendo el entorno completo alrededor de la
// persona. Confirmado con una predicción real del usuario: image_input es un
// array de imágenes (acepta data URI, no hace falta URL pública), prompt es
// un string plano, y aspect_ratio "match_input_image" + height/width 2048 +
// size "2K" + max_images 1 + sequential_image_generation "disabled" son los
// parámetros reales de esa llamada -- no asumidos de la documentación.
const CHANGE_BACKGROUND_MODEL =
  Deno.env.get("REPLICATE_CHANGE_BACKGROUND_MODEL") ?? "bytedance/seedream-4.5";

// Modo "Probar un look" (FASE 5): virtual try-on dedicado, no gpt-image-2.
// Schema confirmado leyendo el openapi_schema real embebido en
// replicate.com/prunaai/p-image-try-on/api/schema (no la documentación
// pública, que no detalla nombres de campo) -- input requerido:
// person_image (string, uri) + garment_images (array de string uri, hasta 11
// soportadas). Salida: un único string (URL), no array. preserve_input_size y
// turbo confirmados por Gonzalo como los valores a fijar (true / false).
const TRY_ON_MODEL = Deno.env.get("REPLICATE_TRY_ON_MODEL") ?? "prunaai/p-image-try-on";

// Modo "Eliminar fondo": bria/remove-background. Schema confirmado leyendo el
// openapi_schema real embebido en replicate.com/bria/remove-background/api/schema
// -- input.image (string, uri), preserve_alpha (boolean, default true),
// content_moderation (boolean, default false, nuestra propia verificación en
// verify-photo ya cubre esto), preserve_partial_alpha (boolean, default true,
// marcado [DEPRECATED] en el schema -- "No longer used in V2 API, use
// preserve_alpha instead" -- se manda igualmente porque no hace daño y así
// queda fijado explícito el valor pedido). Salida: un único string (URL), no
// array.
const REMOVE_BACKGROUND_MODEL =
  Deno.env.get("REPLICATE_REMOVE_BACKGROUND_MODEL") ?? "bria/remove-background";

// Modo "Mejorar calidad": tencentarc/gfpgan, version v1.4. Parámetros fijados
// por el usuario: version "v1.4" (input del propio modelo, algoritmo GFPGAN),
// scale 2. Salida: un único string (URL). Resultado JPEG normal (sin canal
// alfa), a diferencia de bria/remove-background.
// El hash tras ":" es la versión de Replicate (no confundir con el input
// "version": "v1.4" de arriba) -- imprescindible porque gfpgan es un modelo
// comunitario, no oficial: el endpoint /v1/models/{owner}/{name}/predictions
// (sin version pin) solo existe para modelos oficiales y devolvía 404 aquí.
const ENHANCE_QUALITY_MODEL =
  Deno.env.get("REPLICATE_ENHANCE_QUALITY_MODEL") ??
  "tencentarc/gfpgan:0fbacf7afc6c144e5be9767cff80f25aff23e52b0708f17e20f9879b2f21516c";

// Moderación de TEXTO antes de gastar en generación de imagen -- rechaza
// prompts libres que pidan incluir a una persona real/famosa/identificable
// ANTES de llamar a gpt-image-2/seedream (ver runTextModerationCheck más
// abajo). Coste ínfimo (~$0,0002/llamada) comparado con una generación de
// imagen descartada.
const TEXT_MODERATION_MODEL =
  Deno.env.get("REPLICATE_TEXT_MODERATION_MODEL") ?? "google/gemini-3-flash";

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
 * Runs the moderation model against an image (and, for modes with a free
 * prompt, optionally the free-text prompt in the same call — confirmed the
 * model accepts both inputs at once, no separate text-moderation service
 * needed).
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
 * paralelo con runCelebrityCheck (Rekognition) en verify-photo, no de forma
 * secuencial.
 */
export async function runNsfwCheck(imageDataUri: string): Promise<boolean> {
  const prediction = await runPrediction(NSFW_MODEL, { image: imageDataUri }, 30);
  return prediction.output === "nsfw";
}

const TEXT_MODERATION_SYSTEM_INSTRUCTION =
  "Eres un clasificador de moderación de texto. Se te da una instrucción " +
  "escrita por un usuario para editar una foto con IA. Responde ÚNICAMENTE " +
  "con un JSON de una línea, sin texto adicional ni markdown: " +
  '{"is_real_person": true|false}. is_real_person es true si el texto pide ' +
  "generar, añadir, convertir a, o incluir de cualquier forma a una persona " +
  "real, famosa, pública o identificable por nombre propio (actor, cantante, " +
  "político, influencer, personaje histórico, etc), incluso mencionada de " +
  "forma indirecta o con apodo reconocible. is_real_person es false si el " +
  "texto no menciona a ninguna persona real identificable (objetos, ropa, " +
  "lugares, fondos, personas genéricas o ficticias sin nombre propio real).";

/**
 * Moderación de texto libre (google/gemini-3-flash) para los 3 modos con
 * prompt libre (Añadir algo, Eliminar algo, Cambiar fondo) -- se llama ANTES
 * de deductCredit/runImageEdit/runChangeBackground para no gastar crédito ni
 * generación de imagen en un prompt que ya se sabe que se va a rechazar.
 * Confirmado con predicciones reales (ver memoria de proyecto, 2026-08-05):
 * input.system_instruction (no "system_prompt") + input.prompt, output es un
 * array de strings a concatenar (x-cog-array-display "concatenate" en el
 * schema real de Replicate, no un string plano como el resto de modelos de
 * este archivo). thinking_level "none" -- es una clasificación simple, no
 * hace falta razonamiento y encarece/ralentiza la llamada sin mejorar el
 * resultado en las pruebas hechas. Si la salida no es el JSON esperado
 * (fallo de parseo, no de red -- los fallos de red se propagan igual que en
 * runNsfwCheck, no se capturan aquí), se falla cerrado (bloquea la
 * generación) porque esta comprobación cubre la línea no negociable del
 * producto (nunca generar personas reales identificables), a diferencia de
 * otros fallos donde fail-open sería aceptable.
 */
export async function runTextModerationCheck(promptText: string): Promise<boolean> {
  const prediction = await runPrediction(TEXT_MODERATION_MODEL, {
    prompt: promptText,
    system_instruction: TEXT_MODERATION_SYSTEM_INSTRUCTION,
    thinking_level: "none",
    max_output_tokens: 200,
  }, 30);

  const output = prediction.output;
  const text = Array.isArray(output) ? output.join("") : String(output ?? "");
  const match = text.match(/"is_real_person"\s*:\s*(true|false)/i);
  if (!match) {
    console.error("runTextModerationCheck: salida inesperada del modelo, fallando cerrado", text);
    return true;
  }
  return match[1].toLowerCase() === "true";
}

/** DEPRECATED, ver nota junto a FACE_SWAP_MODEL -- sustituida por runCatalogFaceSwap. */
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
 * DEPRECATED: ninguna variante de face-swap (cdingram/face-swap, ni este
 * mismo modo swap de gpt-image-2) dio calidad suficiente tras varias
 * pruebas reales -- sustituido por runCatalogGeneration, que genera sobre la
 * foto del usuario a partir de un scene_prompt escrito por el admin en vez
 * de intercambiar caras sobre la imagen de la plantilla. Se deja sin usar a
 * propósito, no borrar sin decisión explícita, mismo criterio que
 * FACE_SWAP_MODEL/CONTENT_FILTER_DEPLOYMENT.
 */
export async function runCatalogFaceSwap(
  templateDataUri: string,
  userPhotoDataUri: string,
  targetHint: string,
): Promise<GenerationResult> {
  const prompt = `Cambia la cara de la persona ${targetHint} por la cara de la imagen de referencia.`;
  return runImageEdit([templateDataUri, userPhotoDataUri], prompt);
}

export type CatalogTemplateType = "aditiva" | "escena_completa" | "composicion_grafica";

// Sufijo de formato específico por tipo de plantilla, añadido siempre por el
// backend -- el admin nunca lo escribe a mano. Confirmado con pruebas reales
// que el sufijo de selfie mejora mucho la consistencia frente a describir la
// escena como "foto de tercero" en escena_completa; composicion_grafica usa
// el sufijo contrario porque ahí SÍ se busca el acabado de un cartel/portada
// profesional, no una selfie casual. aditiva no necesita sufijo de formato:
// el propio scene_prompt ya preserva la pose/encuadre original del usuario.
const CATALOG_FORMAT_SUFFIX_BY_TYPE: Record<CatalogTemplateType, string> = {
  aditiva: "",
  escena_completa:
    "Selfie tomada por la propia persona, brazo extendido sujetando el móvil, " +
    "encuadre cercano y casual, no una fotografía profesional de tercero.",
  composicion_grafica:
    "Composición fotográfica profesional y estilizada, con iluminación de " +
    "estudio o de producción cuidada, no una foto casual — el retrato de la " +
    "persona debe integrarse con la misma calidad de producción, pose y " +
    "acabado que el resto de la composición.",
};

// Sufijo fijo de fidelidad facial, igual para los 3 tipos -- validado en
// pruebas reales frente a versiones sin esta instrucción explícita.
const CATALOG_FACE_FIDELITY_SUFFIX =
  "Preserva el parecido e identidad facial exactos de la persona. Conserva " +
  "su tono de piel y complexión.";

/**
 * Modo Catálogo (gpt-image-2, misma arquitectura que runImageEdit/modo
 * Añadir algo): genera sobre `userPhotoDataUri` (y, si la plantilla la tiene,
 * `objectReferenceDataUri` como segunda imagen de referencia, ej. una joya a
 * incorporar) siguiendo `scenePrompt` -- el texto que escribe el admin al
 * crear la plantilla. El prompt final se construye aquí combinando
 * scenePrompt con el sufijo de formato según `templateType` y el sufijo fijo
 * de fidelidad facial -- el admin nunca escribe el prompt completo. La
 * imagen de la plantilla (image_storage_path) ya NO se usa para generar,
 * solo como miniatura en el grid de Home.
 */
export async function runCatalogGeneration(
  userPhotoDataUri: string,
  objectReferenceDataUri: string | null,
  scenePrompt: string,
  templateType: CatalogTemplateType,
): Promise<GenerationResult> {
  const formatSuffix = CATALOG_FORMAT_SUFFIX_BY_TYPE[templateType];
  const prompt = [scenePrompt, formatSuffix, CATALOG_FACE_FIDELITY_SUFFIX]
    .filter((part) => part.length > 0)
    .join(" ");
  const referenceImageDataUris = objectReferenceDataUri
    ? [userPhotoDataUri, objectReferenceDataUri]
    : [userPhotoDataUri];
  return runImageEdit(referenceImageDataUris, prompt);
}

/**
 * Modo Añadir algo: edita 1-2 fotos de referencia (`referenceImageDataUris`)
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

// Sufijo fijo para el modo "Eliminar algo" (por texto) -- sin esto,
// gpt-image-2 tiende a dejar artefactos o alterar el resto de la foto al
// rellenar el hueco. El resto de la instrucción (qué quitar) la pone el
// usuario en promptText.
const REMOVE_ELEMENT_SUFFIX =
  "Rellena la zona resultante de forma fotorrealista y coherente con el " +
  "resto de la imagen (iluminación, perspectiva, textura). No alteres " +
  "ninguna otra parte de la foto ni a las personas presentes.";

/**
 * Modo Eliminar algo (por texto): edita 1 foto de referencia quitando lo que
 * describe `promptText`, delegando en runImageEdit igual que Añadir algo.
 */
export async function runElementRemoval(
  photoDataUri: string,
  promptText: string,
): Promise<GenerationResult> {
  const prompt = `Elimina de la foto: ${promptText}. ${REMOVE_ELEMENT_SUFFIX}`;
  return runImageEdit([photoDataUri], prompt);
}

const IDENTITY_PREFIX =
  "Preserva con máxima fidelidad la identidad facial exacta de la " +
  "persona, su expresión facial exacta y su postura corporal exacta " +
  "de la foto original — no cambies rasgos de la cara, no alteres la " +
  "expresión, no modifiques la pose bajo ningún concepto, incluso si " +
  "el lugar descrito implica movimiento o acción. Trata a la persona " +
  "como si se hubiera detenido un instante para hacerse una foto a sí " +
  "misma en ese lugar, manteniendo exactamente su mismo gesto y " +
  "postura de la foto original — nunca como si estuviera participando " +
  "activamente en ninguna acción de la escena.";

const TECHNICAL_SUFFIX =
  "Mantén exactamente el mismo encuadre y recorte que la foto " +
  "original (mismo plano, mismas partes del cuerpo visibles) — si la " +
  "foto original es un selfie de torso para arriba, el resultado " +
  "también debe serlo, sin inventar ni mostrar elementos del cuerpo o " +
  "el suelo que no estaban en el encuadre original. La iluminación, " +
  "temperatura de color y sombras sobre la persona deben coincidir " +
  "exacta y realistamente con el nuevo entorno. Mantén el mismo " +
  "ángulo de cámara de la foto original. Si se describe un lugar " +
  "mediante una ubicación en vez de una vista, interpreta que la " +
  "escena se observa desde ese punto, no que ese lugar aparece como " +
  "objeto en la imagen.";

function buildPrompt(userText: string | null, hasBackgroundImage: boolean): string {
  const locationPart = hasBackgroundImage
    ? `Traslada únicamente el entorno que la rodea exactamente al lugar y fondo mostrados en la segunda imagen de referencia.${userText ? ` ${userText}.` : ""}`
    : `Traslada únicamente el entorno que la rodea a este lugar: ${userText}.`;

  return `${IDENTITY_PREFIX} ${locationPart} ${TECHNICAL_SUFFIX}`;
}

/**
 * Modo "Cambiar fondo": traslada a la persona de `personImageDataUri` al
 * lugar descrito en `placeText` y/o mostrado en `backgroundImageDataUri`
 * (imagen de referencia opcional -- si está presente, `placeText` es solo un
 * matiz adicional, no obligatorio). Ver CHANGE_BACKGROUND_MODEL arriba.
 */
export async function runChangeBackground(
  personImageDataUri: string,
  backgroundImageDataUri: string | null,
  placeText: string,
): Promise<GenerationResult> {
  const prompt = buildPrompt(placeText.trim() || null, backgroundImageDataUri !== null);
  const imageInput = backgroundImageDataUri
    ? [personImageDataUri, backgroundImageDataUri]
    : [personImageDataUri];
  const prediction = await runPrediction(CHANGE_BACKGROUND_MODEL, {
    image_input: imageInput,
    prompt,
    aspect_ratio: "match_input_image",
    height: 2048,
    width: 2048,
    size: "2K",
    max_images: 1,
    sequential_image_generation: "disabled",
  }, 60);
  return toGenerationResult(prediction);
}


/**
 * Modo "Probar un look": viste a la persona de `personImageDataUri` con las
 * prendas de `garmentImageDataUris` (1-4, validado por el caller antes de
 * llamar aquí). Ver TRY_ON_MODEL arriba para la fuente del schema.
 */
export async function runTryOn(
  personImageDataUri: string,
  garmentImageDataUris: string[],
): Promise<GenerationResult> {
  const prediction = await runPrediction(TRY_ON_MODEL, {
    person_image: personImageDataUri,
    garment_images: garmentImageDataUris,
    preserve_input_size: true,
    turbo: false,
  }, 60);
  return toGenerationResult(prediction);
}

/**
 * Modo "Mejorar calidad": restaura y mejora la nitidez de la imagen (y en
 * especial de la cara) con GFPGAN v1.4. Salida JPEG normal sin canal alfa,
 * se guarda igual que el resto de modos (no requiere tratamiento especial
 * de formato). scale=2 dobla la resolución de salida.
 */
export async function runEnhanceQuality(imageDataUri: string): Promise<GenerationResult> {
  const prediction = await runPrediction(ENHANCE_QUALITY_MODEL, {
    img: imageDataUri,
    version: "v1.4",
    scale: 2,
  }, 60);
  return toGenerationResult(prediction);
}

/**
 * Modo "Eliminar fondo": quita el fondo de `imageDataUri` preservando el
 * canal alfa (ver REMOVE_BACKGROUND_MODEL arriba). El caller es responsable
 * de guardar/servir el resultado como PNG -- este modelo no aplana la
 * transparencia como el resto de modos que devuelven JPEG.
 */
export async function runRemoveBackground(imageDataUri: string): Promise<GenerationResult> {
  const prediction = await runPrediction(REMOVE_BACKGROUND_MODEL, {
    image: imageDataUri,
    preserve_alpha: true,
    content_moderation: false,
    preserve_partial_alpha: true,
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
