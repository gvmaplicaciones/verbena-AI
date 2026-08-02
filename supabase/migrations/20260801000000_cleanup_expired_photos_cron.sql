-- Habilita pg_cron (scheduler dentro de Postgres) y pg_net (HTTP asíncrono
-- desde SQL) para poder invocar Edge Functions periódicamente sin depender
-- de un proceso/servidor externo.
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Job "cleanup-expired-photos": cada 15 minutos llama a la Edge Function
-- homónima (ver supabase/functions/cleanup-expired-photos), que:
--   1. Purga del bucket 'verified-photos' las fotos efímeras (is_persisted=false)
--      cuyo expires_at ya venció.
--   2. Borra generaciones completadas no-favoritas fuera del top 30 por usuario
--      (Storage + fila en `generations`).
--   3. Expira sesiones de photo_sessions cuyo expires_at ya venció.
--   4. Reaper: marca 'failed' y reembolsa crédito a generaciones atascadas en
--      'generating' desde hace más de 10 minutos.
-- Antes de esta migración el reaper y las purgas existían en código pero
-- nadie las invocaba -- este cron es la única vía por la que corren en prod.
--
-- El secreto de autenticación (Authorization: Bearer <CRON_SECRET>) NO se
-- guarda en este archivo. Se lee en tiempo de ejecución desde Supabase Vault
-- (nombre 'cron_secret'), insertado una única vez de forma manual con
-- `select vault.create_secret(<valor>, 'cron_secret', ...)` fuera de control
-- de versiones -- así el valor real nunca queda en texto plano en git. El
-- mismo valor está además configurado como secret de Edge Functions
-- (`CRON_SECRET`, ver supabase/functions/cleanup-expired-photos/index.ts).
select cron.schedule(
  'cleanup-expired-photos',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://viegdekwjbrdazpegcpe.supabase.co/functions/v1/cleanup-expired-photos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret'
      )
    ),
    body := '{}'::jsonb
  );
  $$
);
