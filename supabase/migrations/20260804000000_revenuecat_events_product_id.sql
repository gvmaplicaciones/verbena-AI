-- Guarda el product_id crudo de cada evento de RevenueCat -- necesario para
-- depurar el matching contra plans.plan_id/extra_packs.pack_id (p.ej.
-- confirmar si Android manda el sufijo ":base-plan-id" en suscripciones con
-- planes base, algo que hasta ahora no podíamos ver sin este campo).
alter table public.revenuecat_events
  add column product_id text;
