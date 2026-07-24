-- Permite marcar plantillas subidas directamente desde el panel de admin
-- (sin pasar por generate-template-asset/Replicate) sin volver nullable la
-- columna replicate_model -- 'upload' documenta el origen igual que
-- 'flux-1.1-pro'/'flux-dev' documentan el modelo usado.
alter table public.templates drop constraint templates_replicate_model_check;
alter table public.templates add constraint templates_replicate_model_check
  check (replicate_model in ('flux-1.1-pro', 'flux-dev', 'upload'));
