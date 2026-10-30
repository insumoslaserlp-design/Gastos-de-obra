-- =====================================================================
-- Gastos de Obra · parte 4: obras y borrar comprobantes
-- Correr en el SQL Editor DESPUÉS de las partes 1, 2 y 3.
-- Se puede volver a correr sin problema.
-- =====================================================================

-- Solo el administrador crea obras (ya lo permite su permiso general).
-- Si una versión anterior de este archivo dejaba crearlas a todos, se quita.
drop policy if exists cargar_obras on obras;

-- El administrador puede borrar fotos de comprobantes (cuando borra un gasto)
drop policy if exists borrar_comprobante on storage.objects;
create policy borrar_comprobante on storage.objects for delete to authenticated
  using (bucket_id = 'comprobantes' and mi_rol() = 'admin');
