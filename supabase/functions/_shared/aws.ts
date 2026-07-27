// AWS Rekognition RecognizeCelebrities -- sustituye la comprobación de
// figuras públicas (public_figures) que antes hacía flux-content-filter, en
// paralelo con runNsfwCheck (ver verify-photo/index.ts).
//
// Se firma la petición con aws4fetch (SigV4) en vez del SDK completo de AWS:
// mucho más ligero para un edge function y evita arrastrar la cantidad de
// dependencias transitivas del @aws-sdk/client-rekognition.

import { AwsClient } from "npm:aws4fetch@1.0.20";
import { encodeBase64 } from "./bytes.ts";
import { withRetry } from "./retry.ts";

const AWS_ACCESS_KEY_ID = Deno.env.get("AWS_ACCESS_KEY_ID")!;
const AWS_SECRET_ACCESS_KEY = Deno.env.get("AWS_SECRET_ACCESS_KEY")!;
const AWS_REGION = Deno.env.get("AWS_REGION") ?? "eu-central-1";

const awsClient = new AwsClient({
  accessKeyId: AWS_ACCESS_KEY_ID,
  secretAccessKey: AWS_SECRET_ACCESS_KEY,
  region: AWS_REGION,
  service: "rekognition",
});

export interface CelebrityCheckResult {
  detected: boolean;
  raw: unknown;
}

// Umbral mínimo de MatchConfidence (0-100) para contar una entrada de
// CelebrityFaces como detección real. Antes se marcaba "figura pública
// detectada" con cualquier entrada, por baja que fuera su confianza, lo que
// causaba falsos positivos (rechazo de fotos de personas normales con un
// parecido lejano a alguien famoso). 90% es deliberadamente conservador:
// preferimos pecar de cautelosos, porque el coste de un falso negativo aquí
// (dejar pasar a una figura pública real) es peor que el de un falso
// positivo ocasional (rechazar a alguien que no lo es). Ajustable con datos
// reales según la proporción de falsos positivos/negativos que se observe.
const CELEBRITY_MATCH_CONFIDENCE_THRESHOLD = 90;

interface CelebrityFace {
  MatchConfidence?: number;
}

/** true si Rekognition reconoce a alguna celebridad/figura pública en la foto con confianza suficiente. */
export async function runCelebrityCheck(imageBytes: Uint8Array): Promise<CelebrityCheckResult> {
  const body = JSON.stringify({ Image: { Bytes: encodeBase64(imageBytes) } });
  const raw = await withRetry(
    () => callRecognizeCelebrities(body),
    (err) => err instanceof AwsThrottleError,
    "Rekognition RecognizeCelebrities",
  );
  const celebrityFaces = (raw as { CelebrityFaces?: CelebrityFace[] }).CelebrityFaces ?? [];
  const detected = celebrityFaces.some(
    (face) => (face.MatchConfidence ?? 0) >= CELEBRITY_MATCH_CONFIDENCE_THRESHOLD,
  );
  return { detected, raw };
}

// Rekognition (protocolo JSON de AWS) devuelve saturación como HTTP 400 con
// __type ThrottlingException/ProvisionedThroughputExceededException en el
// body, no como un status code dedicado tipo el 429 de Replicate.
class AwsThrottleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AwsThrottleError";
  }
}

async function callRecognizeCelebrities(body: string): Promise<unknown> {
  const res = await awsClient.fetch(`https://rekognition.${AWS_REGION}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": "RekognitionService.RecognizeCelebrities",
    },
    body,
  });

  const text = await res.text();
  if (!res.ok) {
    if (/ThrottlingException|ProvisionedThroughputExceededException|TooManyRequestsException/.test(text)) {
      throw new AwsThrottleError(`Rekognition throttled: ${text}`);
    }
    throw new Error(`Rekognition request failed: ${res.status} ${text}`);
  }

  return JSON.parse(text);
}
