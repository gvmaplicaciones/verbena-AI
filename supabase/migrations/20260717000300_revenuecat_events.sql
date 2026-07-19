-- VerbenAI — deduplicación de eventos de RevenueCat.
-- RevenueCat reintenta la entrega si no respondemos 2xx a tiempo, así que un
-- mismo event.id puede llegar más de una vez; sin esto, un reintento
-- resetearía créditos de tier por segunda vez.
create table public.revenuecat_events (
  id text primary key,       -- event.id de RevenueCat
  event_type text not null,
  app_user_id text not null,
  processed_at timestamptz not null default now()
);

alter table public.revenuecat_events enable row level security;
-- Sin policies: solo la service role (Edge Functions) la toca, nunca el cliente.
