-- Cuarta categoría del Modo Catálogo, añadida al construir el panel de admin.

insert into public.template_categories (id, label, sort_order)
values
  ('eventos', 'Eventos', 3)
on conflict (id) do nothing;
