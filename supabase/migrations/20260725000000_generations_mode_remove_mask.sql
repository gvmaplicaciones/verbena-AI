-- FASE 4: sub-modo "Selecciona lo que quieres borrar" (máscara) de "Eliminar algo"
-- ya genera de verdad (generate-remove-mask, black-forest-labs/flux-fill-pro).
alter table public.generations drop constraint generations_mode_check;
alter table public.generations
  add constraint generations_mode_check check (mode in ('catalog', 'libertad', 'add_element', 'remove_element', 'change_background', 'remove_mask'));
