-- Fecha real de fin del periodo pagado -- necesaria para mostrar "Cancelada
-- -- activa hasta [fecha]" en cliente cuando subscription_status='cancelled'
-- (el auto-renovable está apagado pero el acceso sigue hasta esta fecha).
-- Se rellena desde expiration_at_ms del payload real de RevenueCat
-- (CANCELLATION) y se limpia en el resto de transiciones, donde no aplica.
alter table public.user_credits
  add column expires_at timestamptz;
