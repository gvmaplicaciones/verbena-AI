-- VerbenAI — esquema inicial
-- Fase B. Ver docs/architecture (o el hilo de diseño) para el razonamiento detrás
-- de cada decisión (auth anónima, coste de créditos, borrado solo en EXPIRATION, etc).

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- plans / extra_packs — mapeo de producto de RevenueCat -> créditos a conceder.
-- Evita hardcodear "semanal=15, mensual=60" dentro de las Edge Functions.
-- ---------------------------------------------------------------------------
create table public.plans (
  plan_id text primary key,           -- 'semanal' | 'mensual'
  tier_credits int not null check (tier_credits > 0),
  price_display text not null,
  is_active boolean not null default true
);

create table public.extra_packs (
  pack_id text primary key,           -- 'extra_7'
  credits int not null check (credits > 0),
  price_display text not null,
  is_active boolean not null default true
);

insert into public.plans (plan_id, tier_credits, price_display) values
  ('semanal', 15, '4,99€/semana'),
  ('mensual', 60, '14,99€/mes');

insert into public.extra_packs (pack_id, credits, price_display) values
  ('extra_7', 7, '2,99€');

-- ---------------------------------------------------------------------------
-- user_credits — balance vivo por usuario. Dos contadores independientes:
-- tier_credits se resetea (no acumula) en cada renovación; extra_credits nunca
-- caduca. free_credit_used cubre la única generación gratis (solo Catálogo).
-- ---------------------------------------------------------------------------
create table public.user_credits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  tier_credits int not null default 0,
  tier_total int not null default 0,        -- para pintar "used/total" en Home
  extra_credits int not null default 0,
  free_credit_used boolean not null default false,
  active_plan_id text references public.plans(plan_id),
  subscription_status text not null default 'none'
    check (subscription_status in ('none', 'active', 'cancelled', 'expired')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Crea la fila de créditos automáticamente para cada usuario nuevo (incluye
-- los anónimos de Supabase Auth, que es como arrancan todos los usuarios).
create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.user_credits (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- credit_transactions — ledger append-only. Toda alta/baja de crédito pasa
-- por aquí, incluidos los reembolsos por fallo de generación.
-- ---------------------------------------------------------------------------
create table public.credit_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null check (type in (
    'tier_debit', 'extra_debit', 'free_debit',
    'tier_reset', 'extra_purchase', 'refund'
  )),
  amount int not null,                      -- signo: +añade, -consume
  generation_id uuid,                       -- FK añadida tras crear generations
  balance_tier_after int not null,
  balance_extra_after int not null,
  created_at timestamptz not null default now()
);

create index credit_transactions_user_idx on public.credit_transactions (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- template_categories / templates — Modo Catálogo, gestionado por el admin
-- vía Supabase Studio (sin panel dedicado por ahora).
-- ---------------------------------------------------------------------------
create table public.template_categories (
  id text primary key,                      -- slug: 'gamberro', 'iconos', ...
  label text not null,
  badge_text text,                          -- ej. 'Navidad'
  sort_order int not null default 0,
  is_active boolean not null default true
);

create table public.templates (
  id uuid primary key default gen_random_uuid(),
  category_id text not null references public.template_categories(id),
  name text not null,
  image_storage_path text not null,         -- plantilla base (bucket privado 'templates')
  source_prompt text,                       -- prompt usado para generarla, por si hay que regenerar
  replicate_model text not null check (replicate_model in ('flux-1.1-pro', 'flux-dev')),
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index templates_category_idx on public.templates (category_id, is_active, sort_order);

-- ---------------------------------------------------------------------------
-- verified_photos — resultado de la verificación por hash exacto de archivo.
-- is_persisted = true solo si el usuario tenía suscripción activa en el
-- momento de verificar (entonces vive en el bucket privado 'verified-photos'
-- y alimenta la galería del perfil). Si no, storage_path es efímero y
-- expires_at fuerza su purga (ver cleanup-expired-photos).
-- ---------------------------------------------------------------------------
create table public.verified_photos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  file_hash text not null,
  storage_path text,
  is_persisted boolean not null default false,
  encryption_version smallint not null default 1,   -- 1 = cifrado por defecto de Storage
  status text not null check (status in ('approved', 'rejected', 'appealed')),
  moderation_result jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz,                            -- null si is_persisted; si no, 2-4h tras verificar
  unique (user_id, file_hash)
);

create index verified_photos_user_idx on public.verified_photos (user_id);

-- ---------------------------------------------------------------------------
-- photo_sessions — agrupa "una foto verificada, reutilizable en N
-- generaciones" mientras la sesión siga viva (app abierta, o 2-4h tras
-- cerrarla para usuarios no suscritos).
-- ---------------------------------------------------------------------------
create table public.photo_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  verified_photo_id uuid not null references public.verified_photos(id) on delete cascade,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  status text not null default 'active' check (status in ('active', 'expired'))
);

create index photo_sessions_user_idx on public.photo_sessions (user_id, status);

-- ---------------------------------------------------------------------------
-- generations — cada generación de Catálogo o Libertad. Ambos modos cuestan
-- 1 crédito (tier o extra indistintamente); credit_source = 'split' cuando
-- una misma generación repartió el coste entre tier y extra.
-- ---------------------------------------------------------------------------
create table public.generations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  mode text not null check (mode in ('catalog', 'libertad')),
  template_id uuid references public.templates(id),         -- solo modo catálogo
  prompt_text text,                                          -- solo modo libertad
  photo_session_id uuid not null references public.photo_sessions(id),
  replicate_prediction_id text,
  status text not null default 'pending'
    check (status in ('pending', 'verifying', 'generating', 'completed', 'failed', 'rejected')),
  result_storage_path text,
  encryption_version smallint not null default 1,
  credit_cost int not null default 1,
  credit_source text check (credit_source in ('tier', 'extra', 'free', 'split')),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index generations_user_idx on public.generations (user_id, created_at desc);

alter table public.credit_transactions
  add constraint credit_transactions_generation_fk
  foreign key (generation_id) references public.generations(id) on delete set null;

-- ---------------------------------------------------------------------------
-- moderation_appeals — cola de apelación para falsos positivos del filtro.
-- Revisión manual desde Supabase Studio por ahora, sin panel dedicado.
-- ---------------------------------------------------------------------------
create table public.moderation_appeals (
  id uuid primary key default gen_random_uuid(),
  verified_photo_id uuid not null references public.verified_photos(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  user_reason text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  admin_notes text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create index moderation_appeals_status_idx on public.moderation_appeals (status, created_at);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.user_credits enable row level security;
alter table public.credit_transactions enable row level security;
alter table public.plans enable row level security;
alter table public.extra_packs enable row level security;
alter table public.template_categories enable row level security;
alter table public.templates enable row level security;
alter table public.verified_photos enable row level security;
alter table public.photo_sessions enable row level security;
alter table public.generations enable row level security;
alter table public.moderation_appeals enable row level security;

-- Lectura pública de catálogo activo (usuarios anónimos incluidos).
create policy "plans are readable by anyone" on public.plans
  for select using (is_active);
create policy "extra_packs are readable by anyone" on public.extra_packs
  for select using (is_active);
create policy "template_categories are readable by anyone" on public.template_categories
  for select using (is_active);
create policy "templates are readable by anyone" on public.templates
  for select using (is_active);

-- Cada usuario ve solo lo suyo. Los inserts/updates de negocio (créditos,
-- verificación, generación) los hacen las Edge Functions con la service role,
-- que salta RLS — el cliente nunca escribe estas tablas directamente.
create policy "users read own credits" on public.user_credits
  for select using (auth.uid() = user_id);
create policy "users read own transactions" on public.credit_transactions
  for select using (auth.uid() = user_id);
create policy "users read own verified photos" on public.verified_photos
  for select using (auth.uid() = user_id);
create policy "users read own photo sessions" on public.photo_sessions
  for select using (auth.uid() = user_id);
create policy "users read own generations" on public.generations
  for select using (auth.uid() = user_id);

-- Las apelaciones sí las crea el usuario directamente desde la app.
create policy "users read own appeals" on public.moderation_appeals
  for select using (auth.uid() = user_id);
create policy "users insert own appeals" on public.moderation_appeals
  for insert with check (auth.uid() = user_id);
