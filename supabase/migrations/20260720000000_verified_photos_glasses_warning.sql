-- VerbenAI — el face swap (cdingram/face-swap) da peores resultados cuando
-- la foto del usuario lleva gafas y la plantilla no. Se guarda el resultado
-- de moondream2 (ver _shared/replicate.ts) junto a la verificación para que
-- el warning no bloqueante se pueda devolver también cuando se reutiliza una
-- verificación ya cacheada (handleExisting en verify-photo), no solo en la
-- primera verificación.
alter table public.verified_photos
  add column glasses_detected boolean not null default false;
