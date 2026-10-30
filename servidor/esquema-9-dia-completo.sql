-- =====================================================================
-- Clarita · parte 9: el día completo (lo que salió de los Excel del cliente)
-- Correr en el SQL Editor DESPUÉS de las partes 1 a 8. Se puede volver a correr.
-- No borra ni cambia nada de lo ya cargado.
-- - Obra = cliente + localidad.
-- - Jornada: cómo fue el día (trabajado / no se trabajó / cancelado), horas reales,
--   tramos (mañana y tarde, cada uno con su obra, qué se hizo, horario y si es sin cargo),
--   vehículo y nota.
-- - Caja: plata entregada a alguien para gastos ("José entregó $150.000").
-- - Gastos: si se pagaron con la caja de alguien, y si son a cuenta de un trabajador
--   (por ejemplo "Cigarros Claudio"), para poder descontárselo al pagarle.
-- =====================================================================

alter table obras add column if not exists localidad text;

alter table jornadas add column if not exists estado_dia text not null default 'trabajado';
alter table jornadas drop constraint if exists jornadas_estado_dia_check;
alter table jornadas add constraint jornadas_estado_dia_check
  check (estado_dia in ('trabajado', 'no_trabajo', 'cancelado'));
alter table jornadas add column if not exists horas    numeric(5,2);   -- horas reales del día
alter table jornadas add column if not exists tramos   jsonb;          -- [{obra_id, cliente, localidad, trabajo, cantidad, ml, horario:[["08:00","12:30"]], horas, sin_cargo}]
alter table jornadas add column if not exists vehiculo text;
alter table jornadas add column if not exists nota     text;

-- Un día no trabajado o cancelado queda registrado pero no se paga
create or replace function calcular_jornada() returns trigger
language plpgsql security definer set search_path = public as $$
declare t trabajadores; vh numeric; ve numeric; rec numeric;
begin
  select * into t from trabajadores where id = new.trabajador_id;
  if t.empresa_id is distinct from coalesce(new.empresa_id, mi_empresa()) then
    raise exception 'Ese trabajador no es de tu empresa';
  end if;
  if new.dia is distinct from 'feriado' then
    new.dia := case
      when exists (select 1 from feriados f where f.fecha = new.fecha) then 'feriado'
      when extract(isodow from new.fecha) = 6 then 'sabado'
      when extract(isodow from new.fecha) = 7 then 'domingo'
      else 'habil' end;
  end if;
  if coalesce(new.estado_dia, 'trabajado') <> 'trabajado' then
    new.precio_jornada   := 0;
    new.valor_hora_extra := 0;
    new.horas_extra      := 0;
    new.horas            := 0;
    return new;
  end if;
  vh := t.precio_jornada / t.horas_jornada;
  ve := case t.extra_modo when 'igual' then vh
                          when 'porcentaje' then vh * (1 + t.extra_porcentaje / 100)
                          else t.extra_fijo end;
  rec := case new.dia when 'sabado' then t.recargo_sabado
                      when 'habil' then 0
                      else t.recargo_domingo end;
  new.precio_jornada   := t.precio_jornada;
  new.valor_hora_extra := round(ve * (1 + rec / 100), 2);
  return new;
end $$;

-- ---------- Gastos: con qué plata y a cuenta de quién ----------
alter table gastos add column if not exists de_caja boolean not null default false;  -- se pagó con la caja de trabajador_id
alter table gastos add column if not exists a_cuenta_de uuid references trabajadores(id);

-- Cada trabajador ve los gastos que pagó con su caja y los que son a su cuenta
drop policy if exists tra_gas_mios on gastos;
create policy tra_gas_mios on gastos for select
  using (trabajador_id = mi_trabajador() or a_cuenta_de = mi_trabajador());

-- ---------- Caja: plata entregada para gastos ----------
create table if not exists entregas (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null default mi_empresa() references empresas(id),
  trabajador_id uuid not null references trabajadores(id),   -- quién recibe la plata
  monto         numeric(12,2) not null check (monto > 0),
  fecha         date not null default current_date,
  detalle       text,                                         -- ej: "José entregó"
  cargado_por   uuid not null default auth.uid() references perfiles(id),
  cargado_en    timestamptz not null default now(),
  id_local      text unique
);
alter table entregas enable row level security;
grant select, insert, update, delete on entregas to authenticated;

drop policy if exists solo_mi_empresa on entregas;
create policy solo_mi_empresa on entregas as restrictive for all to authenticated
  using (empresa_id = mi_empresa()) with check (empresa_id = mi_empresa());
drop policy if exists admin_todo on entregas;
create policy admin_todo on entregas for all to authenticated
  using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
drop policy if exists p_ent_ver on entregas;
create policy p_ent_ver on entregas for select to authenticated
  using (puede('cargar_adelantos') or puede('pagos') or puede('ver_informes'));
drop policy if exists p_ent_cargar on entregas;
create policy p_ent_cargar on entregas for insert to authenticated
  with check (puede('cargar_adelantos') and cargado_por = auth.uid());
drop policy if exists tra_ent_ver on entregas;
create policy tra_ent_ver on entregas for select to authenticated
  using (trabajador_id = mi_trabajador());

-- La entrega tiene que ser para un trabajador de la misma empresa
create or replace function entrega_misma_empresa() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from trabajadores t where t.id = new.trabajador_id and t.empresa_id = new.empresa_id) then
    raise exception 'Ese trabajador no es de tu empresa';
  end if;
  return new;
end $$;
drop trigger if exists entregas_empresa on entregas;
create trigger entregas_empresa before insert or update on entregas
  for each row execute function entrega_misma_empresa();
