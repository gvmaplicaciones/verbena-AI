-- VerbenAI — acceso del panel de admin interno (proyecto separado, no la app
-- Flutter). Un único usuario de Supabase Auth (email/contraseña) gestiona el
-- catálogo de plantillas sin pasar por Supabase Studio a mano.
--
-- admin_users marca qué auth.users pueden operar como admin. Las políticas
-- de abajo se suman (OR) a las de lectura pública ya existentes en
-- 20260717000000_init_schema.sql / 20260717000100_storage_buckets.sql — no
-- las reemplazan, así que la app de usuarios finales sigue viendo solo
-- is_active = true sin cambios.

create table public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade
);

alter table public.admin_users enable row level security;

-- Necesaria para que la subquery de las políticas de abajo pueda resolverse
-- cuando la ejecuta el propio admin autenticado.
create policy "admin reads own admin_users row"
  on public.admin_users for select
  using (auth.uid() = user_id);

create policy "admin full access to templates"
  on public.templates for all
  using (exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
  with check (exists (select 1 from public.admin_users a where a.user_id = auth.uid()));

create policy "admin full access to template_categories"
  on public.template_categories for all
  using (exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
  with check (exists (select 1 from public.admin_users a where a.user_id = auth.uid()));

create policy "admin manages templates storage"
  on storage.objects for all
  using (
    bucket_id = 'templates'
    and exists (select 1 from public.admin_users a where a.user_id = auth.uid())
  )
  with check (
    bucket_id = 'templates'
    and exists (select 1 from public.admin_users a where a.user_id = auth.uid())
  );
