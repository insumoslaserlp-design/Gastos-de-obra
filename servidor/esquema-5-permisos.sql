-- =====================================================================
-- Gastos de Obra · parte 5: permisos por rol
-- Correr en el SQL Editor DESPUÉS de las partes 1 a 4. Se puede volver a correr.
-- - Suma el rol "asistente".
-- - Cada rol tiene permisos que el administrador prende o apaga desde la app.
-- - El administrador siempre puede todo. El trabajador, de entrada, solo ve lo suyo.
-- =====================================================================

alter type rol add value if not exists 'asistente';

create table if not exists permisos_rol (
  rol     text not null,
  permiso text not null,
  primary key (rol, permiso)
);
alter table permisos_rol enable row level security;
drop policy if exists ver_permisos on permisos_rol;
create policy ver_permisos on permisos_rol for select to authenticated using (true);
drop policy if exists admin_todo on permisos_rol;
create policy admin_todo on permisos_rol for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');

-- Permisos de entrada (el administrador los puede cambiar después)
insert into permisos_rol (rol, permiso) values
  ('encargado','cargar_gastos'), ('encargado','cargar_jornadas'), ('encargado','ver_informes'),
  ('encargado','ver_comprobantes'), ('encargado','aprobar'),
  ('asistente','cargar_gastos'), ('asistente','ver_comprobantes')
on conflict do nothing;

-- ¿El usuario actual tiene este permiso?
create or replace function puede(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from perfiles pf
     where pf.id = auth.uid()
       and (pf.rol = 'admin'
            or exists (select 1 from permisos_rol r where r.rol = pf.rol::text and r.permiso = p))
  )
$$;

-- Lo que carga alguien sin permiso de aprobar queda pendiente
create or replace function estado_segun_rol() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not puede('aprobar') then new.estado := 'pendiente'; end if;
  return new;
end $$;

-- ---- Se reemplazan los permisos fijos por rol por permisos configurables ----
drop policy if exists enc_trab_ver   on trabajadores;
drop policy if exists enc_jor_ver    on jornadas;
drop policy if exists enc_jor_cargar on jornadas;
drop policy if exists enc_gas_ver    on gastos;
drop policy if exists enc_gas_cargar on gastos;
drop policy if exists tra_jor_carga  on jornadas;
drop policy if exists tra_gas_carga  on gastos;
-- (se mantienen las de "ver lo propio": tra_ficha, tra_jor_ver, tra_gas_ver, tra_ade_ver, tra_pag_ver)

drop policy if exists p_trab_ver on trabajadores;
create policy p_trab_ver on trabajadores for select
  using (puede('cargar_jornadas') or puede('cargar_adelantos') or puede('pagos') or puede('ver_informes'));

drop policy if exists p_jor_ver on jornadas;
create policy p_jor_ver on jornadas for select
  using (puede('cargar_jornadas') or puede('ver_informes') or puede('pagos') or puede('aprobar'));
drop policy if exists p_jor_cargar on jornadas;
create policy p_jor_cargar on jornadas for insert
  with check (puede('cargar_jornadas') and cargado_por = auth.uid());
drop policy if exists p_jor_editar on jornadas;
create policy p_jor_editar on jornadas for update
  using (puede('aprobar') or puede('pagos')) with check (puede('aprobar') or puede('pagos'));

drop policy if exists p_gas_ver on gastos;
create policy p_gas_ver on gastos for select
  using (puede('ver_informes') or puede('ver_comprobantes') or puede('aprobar'));
drop policy if exists p_gas_cargar on gastos;
create policy p_gas_cargar on gastos for insert
  with check (puede('cargar_gastos') and cargado_por = auth.uid());
drop policy if exists p_gas_editar on gastos;
create policy p_gas_editar on gastos for update using (puede('aprobar')) with check (puede('aprobar'));

drop policy if exists p_ade_ver on adelantos;
create policy p_ade_ver on adelantos for select using (puede('cargar_adelantos') or puede('pagos'));
drop policy if exists p_ade_cargar on adelantos;
create policy p_ade_cargar on adelantos for insert with check (puede('cargar_adelantos') and cargado_por = auth.uid());

drop policy if exists p_cob_ver on cobros;
create policy p_cob_ver on cobros for select using (puede('cargar_cobros') or puede('ver_cobros'));
drop policy if exists p_cob_cargar on cobros;
create policy p_cob_cargar on cobros for insert with check (puede('cargar_cobros') and cargado_por = auth.uid());

drop policy if exists p_pag_ver on pagos;
create policy p_pag_ver on pagos for select using (puede('pagos'));
drop policy if exists p_pag_cargar on pagos;
create policy p_pag_cargar on pagos for insert with check (puede('pagos') and cargado_por = auth.uid());

-- Fotos de comprobantes: cada uno ve las suyas; quien tenga permiso ve todas
drop policy if exists ver_comprobante on storage.objects;
create policy ver_comprobante on storage.objects for select to authenticated
  using (bucket_id = 'comprobantes'
         and ((storage.foldername(name))[1] = auth.uid()::text or puede('ver_comprobantes') or puede('aprobar')));
