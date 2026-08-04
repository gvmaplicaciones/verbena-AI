-- Dedupe de concesiones del pack extra: ahora hay dos caminos que pueden
-- llamar a grantExtraPack() para la MISMA compra -- el webhook asíncrono
-- (NON_RENEWING_PURCHASE) y reconcileSubscriberState() (síncrono, llamado
-- por el cliente justo tras comprar, para no depender de que el webhook
-- llegue a tiempo para refrescar la UI). Se dedupea por store_transaction_id,
-- el único identificador presente tanto en el payload del webhook
-- (`transaction_id`) como en la respuesta real de GET /subscribers
-- (`non_subscriptions[].store_transaction_id`) -- confirmado contra una
-- compra real: "GPA.3373-0753-7251-64508". No se usa `non_subscriptions[].id`
-- (formato "o1_..."): es un identificador interno de RevenueCat para esa fila
-- de la API, no el mismo valor que manda el webhook.
create table public.extra_pack_grants (
  store_transaction_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  pack_id text not null,
  granted_at timestamptz not null default now()
);
