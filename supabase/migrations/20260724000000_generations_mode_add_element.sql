-- FASE 1 del grid de 4 modos: "Añadir algo" ya genera de verdad
-- (generate-add-element, antes generate-libertad). 'libertad' se conserva
-- en el check solo por las filas históricas de generations -- ya no hay
-- ninguna Edge Function ni pantalla que inserte ese valor.
alter table public.generations drop constraint generations_mode_check;
alter table public.generations
  add constraint generations_mode_check check (mode in ('catalog', 'libertad', 'add_element'));
