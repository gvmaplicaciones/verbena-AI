-- FASE 3 del grid de 4 modos: "Cambiar fondo" ya genera de verdad
-- (generate-change-background, bytedance/seedream-4.5).
alter table public.generations drop constraint generations_mode_check;
alter table public.generations
  add constraint generations_mode_check check (mode in ('catalog', 'libertad', 'add_element', 'remove_element', 'change_background'));
