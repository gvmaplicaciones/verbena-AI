-- Modo "Eliminar fondo": añade 'remove_background' a los modos válidos.
alter table public.generations drop constraint generations_mode_check;
alter table public.generations
  add constraint generations_mode_check check (mode in (
    'catalog', 'libertad', 'add_element', 'remove_element',
    'change_background', 'remove_mask', 'add_mask', 'modify_mask', 'try_on',
    'remove_background'
  ));
