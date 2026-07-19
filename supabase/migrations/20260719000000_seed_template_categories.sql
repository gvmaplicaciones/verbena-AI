-- Categorías iniciales del Modo Catálogo (ver comentario en template_categories,
-- 20260717000000_init_schema.sql). No existía seed hasta ahora.

insert into public.template_categories (id, label, sort_order)
values
  ('gamberro', 'Gamberro', 0),
  ('iconos', 'Iconos culturales', 1),
  ('deportivo', 'Deportivo', 2)
on conflict (id) do nothing;
