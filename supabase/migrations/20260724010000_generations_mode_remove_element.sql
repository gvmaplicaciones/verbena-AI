-- FASE 2a del grid de 4 modos: "Eliminar algo" (sub-modo "por texto") ya
-- genera de verdad (generate-remove-element).
alter table public.generations drop constraint generations_mode_check;
alter table public.generations
  add constraint generations_mode_check check (mode in ('catalog', 'libertad', 'add_element', 'remove_element'));
