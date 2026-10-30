-- =====================================================================
-- Clarita · parte 11: el creador entra a cada empresa, bajas de trabajadores
-- y reinicio de una empresa.
-- Correr en el SQL Editor DESPUÉS de las partes 1 a 10. Se puede volver a correr.
-- No borra nada de lo ya cargado.
-- - El creador elige "Panel general" o "Entrar a la empresa X" y ve esa empresa
--   como su administrador.
-- - El administrador da de baja a un trabajador: guardando sus registros o borrándolos.
-- - El creador puede borrar todo lo cargado por una empresa para arrancar de cero
--   (quedan la empresa, sus usuarios, categorías, tipos de trabajo y permisos).
-- =====================================================================

-- ---------- El creador entra a una empresa ----------
alter table perfiles add column if not exists viendo_empresa uuid references empresas(id) on delete set null;

-- Mi empresa: la mía (si está activa y no venció) o, si soy el creador, la que estoy viendo
create or replace function mi_empresa() returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.empresa_id from perfiles p join empresas e on e.id = p.empresa_id
      where p.id = auth.uid() and e.activa and (e.vence is null or e.vence >= current_date)),
    (select p.viendo_empresa from perfiles p where p.id = auth.uid() and p.creador))
$$;

create or replace function puede(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from perfiles pf
     where pf.id = auth.uid() and coalesce(pf.empresa_id, pf.viendo_empresa) = mi_empresa()
       and (pf.rol = 'admin'
            or exists (select 1 from permisos_rol r
                        where r.empresa_id = pf.empresa_id and r.rol = pf.rol::text and r.permiso = p))
  )
$$;

create or replace function mi_empresa_estado()
returns table (id uuid, nombre text, slug text, firma text, activa boolean, vence date)
language sql stable security definer set search_path = public as $$
  select e.id, e.nombre, e.slug, e.firma, e.activa and (e.vence is null or e.vence >= current_date), e.vence
    from perfiles p join empresas e on e.id = coalesce(p.empresa_id, case when p.creador then p.viendo_empresa end)
   where p.id = auth.uid()
$$;

-- Nombres de quién cargó cada cosa: los de la empresa y yo mismo
create or replace view quienes with (security_invoker = false) as
  select id, nombre, rol from perfiles where empresa_id = mi_empresa() or id = auth.uid();
revoke all on quienes from anon;
grant select on quienes to authenticated;

-- Elegir a qué empresa entrar (null = panel general)
create or replace function entrar_empresa(p_empresa uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not es_creador() then raise exception 'Solo el creador de la app'; end if;
  if p_empresa is not null and not exists (select 1 from empresas where id = p_empresa) then
    raise exception 'Esa empresa no existe';
  end if;
  update perfiles set viendo_empresa = p_empresa where id = auth.uid();
end $$;
revoke all on function entrar_empresa(uuid) from public;
grant execute on function entrar_empresa(uuid) to authenticated;

-- Nadie más puede tocar "viendo_empresa"
create or replace function proteger_viendo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.viendo_empresa is distinct from old.viendo_empresa and not es_creador() then
    raise exception 'Solo el creador de la app';
  end if;
  return new;
end $$;
drop trigger if exists perfiles_viendo on perfiles;
create trigger perfiles_viendo before update on perfiles
  for each row execute function proteger_viendo();

-- ---------- Dar de baja a un trabajador ----------
-- p_borrar = false: queda inactivo y se guardan todos sus registros.
-- p_borrar = true:  se borran sus jornadas, pagos, adelantos, caja y gastos a su cuenta.
--                   Los gastos de obra que pagó él quedan (son gastos de la empresa), sin su nombre.
-- En los dos casos su cuenta deja de estar vinculada a la ficha (ya no ve su detalle).
create or replace function baja_trabajador(p_trab uuid, p_borrar boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() <> 'admin' or mi_empresa() is null then raise exception 'Solo el administrador'; end if;
  if not exists (select 1 from trabajadores where id = p_trab and empresa_id = mi_empresa()) then
    raise exception 'Ese trabajador no es de tu empresa';
  end if;
  update perfiles set trabajador_id = null where trabajador_id = p_trab;
  if not p_borrar then
    update trabajadores set activo = false where id = p_trab;
    return;
  end if;
  delete from jornadas  where trabajador_id = p_trab;
  delete from adelantos where trabajador_id = p_trab;
  delete from entregas  where trabajador_id = p_trab;
  delete from pagos     where trabajador_id = p_trab;
  delete from gastos    where a_cuenta_de   = p_trab;
  update gastos set trabajador_id = null, de_caja = false where trabajador_id = p_trab;
  delete from trabajadores where id = p_trab;
end $$;
revoke all on function baja_trabajador(uuid, boolean) from public;
grant execute on function baja_trabajador(uuid, boolean) to authenticated;

-- ---------- Reiniciar una empresa (solo el creador) ----------
-- Borra jornadas, gastos, adelantos, caja, cobros, pagos, trabajadores y obras.
-- Devuelve las fotos de comprobantes que quedaron sueltas, para borrarlas.
create or replace function reiniciar_empresa(p_empresa uuid)
returns table (foto text)
language plpgsql security definer set search_path = public as $$
declare fotos text[];
begin
  if not es_creador() then raise exception 'Solo el creador de la app'; end if;
  select coalesce(array_agg(comprobante), '{}') into fotos
    from gastos where empresa_id = p_empresa and comprobante is not null;
  delete from jornadas  where empresa_id = p_empresa;
  delete from gastos    where empresa_id = p_empresa;
  delete from adelantos where empresa_id = p_empresa;
  delete from entregas  where empresa_id = p_empresa;
  delete from cobros    where empresa_id = p_empresa;
  delete from pagos     where empresa_id = p_empresa;
  update perfiles set trabajador_id = null where empresa_id = p_empresa;
  delete from trabajadores where empresa_id = p_empresa;
  delete from obras        where empresa_id = p_empresa;
  return query select unnest(fotos);
end $$;
revoke all on function reiniciar_empresa(uuid) from public;
grant execute on function reiniciar_empresa(uuid) to authenticated;

-- El creador puede borrar fotos de comprobantes (las que quedan sueltas al reiniciar)
drop policy if exists creador_borra_comprobante on storage.objects;
create policy creador_borra_comprobante on storage.objects for delete to authenticated
  using (bucket_id = 'comprobantes' and es_creador());
