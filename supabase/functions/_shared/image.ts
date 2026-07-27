// Fijado en 1.3.0 (no 1.4.0): la 1.4.0 rompe el arranque en el runtime de
// Supabase Edge Functions con "Relative import path 'env' not prefixed with
// / or ./ or ../" al cargar su gif.wasm -- bug confirmado en
// github.com/matmen/ImageScript/issues/45, sin fix del maintainer todavía.
import { Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

/**
 * Usado solo por generate-add-mask: stability-ai/stable-diffusion-inpainting
 * fuerza image/mask a 512x512 (squash, sin conservar aspect ratio) y no
 * expone width/height como parámetro (ver SD_INPAINTING_MODEL en
 * _shared/replicate.ts). Reescalar el resultado a las dimensiones exactas de
 * la foto original deshace esa distorsión (compresión y estiramiento con el
 * mismo factor se cancelan geométricamente).
 */
export async function resizeToMatch(
  imageBytes: Uint8Array,
  targetWidth: number,
  targetHeight: number,
): Promise<{ bytes: Uint8Array; contentType: string }> {
  const img = await Image.decode(imageBytes);
  img.resize(targetWidth, targetHeight);
  const encoded = await img.encodeJPEG(90);
  return { bytes: encoded, contentType: "image/jpeg" };
}

export async function decodeDimensions(
  imageBytes: Uint8Array,
): Promise<{ width: number; height: number }> {
  const img = await Image.decode(imageBytes);
  return { width: img.width, height: img.height };
}
