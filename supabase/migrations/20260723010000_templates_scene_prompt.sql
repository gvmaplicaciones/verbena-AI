-- Modo Catálogo pasa de face-swap (cdingram / gpt-image-2 en modo swap) a
-- generación por prompt sobre la foto del usuario, misma arquitectura que ya
-- usa modo Libertad -- tras varias pruebas ninguna variante de face-swap daba
-- calidad suficiente. La imagen de la plantilla (image_storage_path) deja de
-- usarse para generar, se conserva solo como miniatura del grid de Home.
--
-- target_hint (añadido hoy mismo en 20260723000000, nunca llegó a usarse en
-- producción más que en una plantilla) se sustituye por scene_prompt: la
-- instrucción de generación completa que escribe el admin, no solo "a quién
-- sustituir".
alter table public.templates drop column target_hint;
alter table public.templates add column scene_prompt text;

-- 'aditiva': el scene_prompt añade/cambia algo sobre la foto original del
-- usuario preservando su pose/encuadre/fondo (ej. añadir un reloj de lujo).
-- 'escena_completa': el scene_prompt describe una escena nueva por completo
-- -- el backend añade siempre un sufijo fijo de formato selfie (ver
-- runCatalogGeneration en _shared/replicate.ts) porque las pruebas reales
-- confirmaron que mejora mucho la consistencia frente a "foto de tercero".
-- 'composicion_grafica': escena tipo cartel/portada/retrato de estudio, donde
-- el sufijo fijo es el contrario (producción profesional cuidada, no selfie
-- casual) -- ver mismo archivo.
alter table public.templates add column template_type text
  check (template_type in ('aditiva', 'escena_completa', 'composicion_grafica'));

-- Imagen opcional que sube el admin (ej. un collar) para incorporarla como
-- segunda imagen de referencia junto a la foto del usuario -- el propio
-- scene_prompt de esa plantilla es quien la referencia en texto (ej. "luciendo
-- el collar de la imagen de referencia adicional"), no hace falta ningún
-- sufijo fijo adicional en el backend para esto.
alter table public.templates add column object_reference_image text;

-- Nullable a propósito: las 16 plantillas existentes se migran a mano tras
-- desplegar el nuevo generate-catalog (ver tarea de aplicar las 15 + la ya
-- corregida "Entrevistado en el congreso"), generate-catalog rechaza con 500
-- cualquier plantilla activa sin scene_prompt/template_type, igual que hacía
-- antes con target_hint.
