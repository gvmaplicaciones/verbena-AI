-- FASE 5: modo "Probar un look" + Armario de prendas.
--
-- garments — prendas guardadas del Armario (solo socios, ver Profile). A
-- diferencia de verified_photos, aquí solo se insertan filas aprobadas: si el
-- filtro de moderación rechaza la prenda en upload-garment, nunca llega a
-- ocupar uno de los 30 huecos por usuario (el límite se valida server-side en
-- esa misma función, no solo en el cliente). Prendas nuevas subidas ad-hoc
-- dentro del flujo de generación (sin guardarlas en el Armario) NO pasan por
-- esta tabla -- reutilizan verify-photo/verified_photos igual que cualquier
-- otra foto de referencia, ver generate-try-on.
create table public.garments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  -- Nullable: null significa "purgada" (ver expireSubscription/purgeGarments)
  -- -- la fila se conserva para no romper el historial de generations que la
  -- referencien vía garment_ids, solo se pierde el archivo.
  storage_path text,
  moderation_result jsonb,
  created_at timestamptz not null default now()
);

create index garments_user_idx on public.garments (user_id, created_at desc);

alter table public.garments enable row level security;

create policy "users read own garments" on public.garments
  for select using (auth.uid() = user_id);

-- Escrituras (insert/delete) solo vía Edge Functions con service role,
-- mismo criterio que el resto de tablas de negocio (ver init_schema.sql).

insert into storage.buckets (id, name, public)
values ('garments', 'garments', false)
on conflict (id) do nothing;

create policy "users read own garments in storage"
  on storage.objects for select
  using (
    bucket_id = 'garments'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- Modo "Probar un look" (prunaai/p-image-try-on): persona (photo_session_id,
-- igual que el resto de modos) + hasta 4 prendas de referencia, mezclando dos
-- orígenes posibles por prenda -- ad-hoc (garment_photo_session_ids, vía
-- verify-photo/photo_sessions, ephemeral) o del Armario
-- (garment_ids, vía la tabla garments, persistente). Arrays sin FK propia
-- (Postgres no soporta FK por elemento de array) -- la propiedad de cada id
-- se revalida en cada request en generate-try-on, igual que con
-- photo_session_id/second_photo_session_id.
alter table public.generations
  add column garment_photo_session_ids uuid[],
  add column garment_ids uuid[];

alter table public.generations drop constraint generations_mode_check;
alter table public.generations
  add constraint generations_mode_check check (mode in (
    'catalog', 'libertad', 'add_element', 'remove_element',
    'change_background', 'remove_mask', 'add_mask', 'modify_mask', 'try_on'
  ));
