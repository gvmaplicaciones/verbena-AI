-- VerbenAI — buckets de Storage privados.
-- Decisión Fase A/B: cifrado en reposo por defecto de Supabase Storage
-- (AES-256 gestionado por la plataforma). Nada de claves propias por ahora.
-- Acceso exclusivamente vía URLs firmadas de vida corta emitidas por las
-- Edge Functions; ningún bucket es público.

insert into storage.buckets (id, name, public)
values
  ('templates', 'templates', false),        -- plantillas base, sube el admin
  ('verified-photos', 'verified-photos', false),  -- solo persistido si is_persisted=true
  ('generation-results', 'generation-results', false)
on conflict (id) do nothing;

-- Convención de rutas: '<user_id>/<file>.jpg' para verified-photos y
-- generation-results, así el policy de abajo puede comparar el primer
-- segmento de la ruta con auth.uid() sin tabla intermedia.

create policy "users read own verified photos in storage"
  on storage.objects for select
  using (
    bucket_id = 'verified-photos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "users read own generation results in storage"
  on storage.objects for select
  using (
    bucket_id = 'generation-results'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "templates are readable by anyone"
  on storage.objects for select
  using (bucket_id = 'templates');

-- Escrituras (insert/update/delete) las hacen únicamente las Edge Functions
-- con la service role, que ignora RLS: no se define policy de escritura
-- para authenticated/anon a propósito.
