-- =====================================================================
-- Gastos de Obra · parte 4: obras escritas a mano y borrar comprobantes
-- Correr en el SQL Editor DESPUÉS de las partes 1, 2 y 3.
-- =====================================================================

-- Cualquiera que haya entrado puede crear una obra nueva al escribir su nombre
drop policy if exists cargar_obras on obras;
create policy cargar_obras on obras for insert to authenticated with check (auth.uid() is not null);

-- El administrador puede borrar fotos de comprobantes (cuando borra un gasto)
drop policy if exists borrar_comprobante on storage.objects;
create policy borrar_comprobante on storage.objects for delete to authenticated
  using (bucket_id = 'comprobantes' and mi_rol() = 'admin');
