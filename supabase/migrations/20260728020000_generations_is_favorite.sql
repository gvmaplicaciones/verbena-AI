-- Favoritos de "Mis creaciones": máximo 10 por usuario, nunca tocados por el
-- cron de limpieza. El límite y la lógica de borrado al desmarcar se validan
-- en toggle-generation-favorite y delete-generation (Edge Functions).
alter table public.generations
  add column is_favorite boolean not null default false;

-- Índice para el cron de limpieza (cleanup-expired-photos) y para la consulta
-- "¿cuántas no-favoritas más recientes que esta?" del cliente al desmarcar.
create index generations_cleanup_idx
  on public.generations (user_id, is_favorite, created_at desc)
  where status = 'completed';
