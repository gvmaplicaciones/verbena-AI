-- VerbenAI — se retira la comprobación de gafas (moondream2, ver
-- 20260720000000_verified_photos_glasses_warning.sql): ya no aplica porque
-- ningún modo usa face-swap dedicado, todos usan modelos de edición por
-- instrucción (gpt-image-2, Seedream, flux-fill-pro) sin ese problema
-- conocido de face-swap con gafas.
alter table public.verified_photos
  drop column glasses_detected;
