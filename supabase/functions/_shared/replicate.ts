const REPLICATE_API_TOKEN = Deno.env.get("REPLICATE_API_TOKEN")!;

// TODO(confirmar antes de producción): slug exacto del modelo en Replicate.
// "flux-content-filter" es el nombre funcional acordado en el diseño; el
// identificador real (owner/modelo[:version]) hay que confirmarlo en
// replicate.com antes de salir a producción. Se deja configurable por env
// var para no tener que redeploy-ear cuando se confirme.
const CONTENT_FILTER_MODEL =
  Deno.env.get("REPLICATE_CONTENT_FILTER_MODEL") ??
  "lucataco/flux-content-filter";

export interface ContentFilterResult {
  passed: boolean;
  raw: unknown;
  reason?: string;
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

  const res = await fetch(
    `https://api.replicate.com/v1/models/${CONTENT_FILTER_MODEL}/predictions`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${REPLICATE_API_TOKEN}`,
        "Content-Type": "application/json",
        // Espera síncrona hasta 30s -- la moderación es rápida y barata
        // ($0,0042); si no da tiempo, cae a "processing" y se resuelve por
        // polling con el id de predicción devuelto.
        Prefer: "wait=30",
      },
      body: JSON.stringify({ input }),
    },
  );

  if (!res.ok) {
    throw new Error(`Replicate content-filter request failed: ${res.status} ${await res.text()}`);
  }

  let prediction = await res.json();

  if (prediction.status !== "succeeded" && prediction.status !== "failed") {
    prediction = await pollPrediction(prediction.id);
  }

  if (prediction.status === "failed") {
    throw new Error(`Replicate content-filter prediction failed: ${JSON.stringify(prediction.error)}`);
  }

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

async function pollPrediction(id: string, timeoutMs = 30_000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const res = await fetch(`https://api.replicate.com/v1/predictions/${id}`, {
      headers: { Authorization: `Bearer ${REPLICATE_API_TOKEN}` },
    });
    const prediction = await res.json();
    if (prediction.status === "succeeded" || prediction.status === "failed") {
      return prediction;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`Replicate content-filter prediction ${id} timed out`);
}
