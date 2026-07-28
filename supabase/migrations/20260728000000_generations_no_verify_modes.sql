-- Modos "Eliminar fondo" y "Mejorar calidad" no pasan por verify-photo
-- (no sintetizan contenido nuevo), así que no generan photo_session_id.
-- Se hace nullable para permitir el insert sin sesión verificada.
alter table public.generations alter column photo_session_id drop not null;

-- Añade 'enhance_quality' a los modos válidos.
alter table public.generations drop constraint generations_mode_check;
alter table public.generations
  add constraint generations_mode_check check (mode in (
    'catalog', 'libertad', 'add_element', 'remove_element',
    'change_background', 'remove_mask', 'add_mask', 'modify_mask', 'try_on',
    'remove_background', 'enhance_quality'
  ));
