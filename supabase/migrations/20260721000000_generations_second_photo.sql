-- VerbenAI — Modo Libertad admite ahora una segunda foto de referencia
-- opcional (openai/gpt-image-2 acepta hasta 2 input_images, ver
-- _shared/replicate.ts). Nullable porque la inmensa mayoría de generaciones
-- (Catálogo entero, y Libertad con una sola foto) no la usan.
alter table public.generations
  add column second_photo_session_id uuid references public.photo_sessions(id);
