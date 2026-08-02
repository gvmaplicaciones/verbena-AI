-- El job "cleanup-expired-photos" (ver 20260801000000) usaba el timeout por
-- defecto de net.http_post (5000ms), insuficiente: una prueba manual real
-- contra prod tardó ~7-8s en completar (purga de Storage + varias consultas
-- encadenadas) y el request se marcó timed_out=true sin llegar a ejecutar
-- nada. cron.schedule() con el mismo nombre de job reemplaza la definición
-- anterior en vez de crear un duplicado.
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
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
  $$
);
