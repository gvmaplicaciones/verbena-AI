// Reintento genérico con backoff exponencial + jitter, compartido entre
// Replicate (_shared/replicate.ts) y AWS Rekognition (_shared/aws.ts) --
// mismo presupuesto y curva de espera para cualquier proveedor externo que
// pueda saturarse (429 de Replicate, ThrottlingException de AWS, etc.).
// Solo reintenta el error que `isRetryable` reconoce como saturación;
// cualquier otro fallo se propaga tal cual en el primer intento.

// Techo bajo a propósito: la petición que se reintenta (crear predicción o
// consultar su estado) responde rápido incluso cuando el proveedor está
// saturado, así que 3 reintentos + backoff no deja al usuario esperando
// mucho más en la pantalla de Processing. El backoff real (~1s/2s/4s) casi
// nunca llega a agotar el presupuesto de 20s.
export const RETRY_MAX_ATTEMPTS = 3;
const RETRY_BASE_DELAY_MS = 1000;
export const RETRY_BUDGET_MS = 20_000;

// Backoff exponencial (~1s, ~2s, ~4s...) con jitter del 75%-125% para que
// varias llamadas en curso en paralelo (p.ej. NSFW, Rekognition y glasses
// check de una misma verify-photo) no reintenten todas en el mismo instante.
export function backoffDelayMs(attempt: number): number {
  const base = RETRY_BASE_DELAY_MS * 2 ** attempt;
  return base * (0.75 + Math.random() * 0.5);
}

export async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

/** Reintenta `fn` solo si falla con un error que `isRetryable` reconoce -- cualquier otro error se propaga sin tocar. */
export async function withRetry<T>(
  fn: () => Promise<T>,
  isRetryable: (err: unknown) => boolean,
  label: string,
): Promise<T> {
  const startedAt = Date.now();
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (!isRetryable(err)) throw err;
      if (attempt >= RETRY_MAX_ATTEMPTS || Date.now() - startedAt >= RETRY_BUDGET_MS) {
        throw err;
      }
      const delay = backoffDelayMs(attempt);
      console.warn(`${label}: saturado, reintento ${attempt + 1}/${RETRY_MAX_ATTEMPTS} en ${Math.round(delay)}ms`);
      await sleep(delay);
    }
  }
}
