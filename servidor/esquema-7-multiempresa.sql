-- =====================================================================
-- Clarita la Cuenta · parte 7: multiempresa
-- Correr en el SQL Editor DESPUÉS de las partes 1 a 6. Se puede volver a correr.
-- - Cada empresa ve solo sus datos. Lo controla la base, no la app.
-- - El creador de la app da de alta las empresas, las pausa y les pone vencimiento.
-- - Se entra a una empresa con su enlace: claritalacuenta.com.ar/<link>
-- - Una persona (un teléfono) pertenece a una sola empresa.
-- - Todo lo que ya estaba cargado pasa a la empresa 1.
-- =====================================================================

create table if not exists empresas (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  slug       text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{2,39}$'),
  dueno_tel  text,                       -- teléfono del dueño (10 números): entra como administrador
  firma      text,                       -- firma del mensaje de WhatsApp de esta empresa
  activa     boolean not null default true,
  vence      date,                       -- vacío = sin vencimiento
  creada_en  timestamptz not null default now()
);
alter table empresas enable row level security;

-- Empresa 1: la que ya existía
insert into empresas (nombre, slug, firma)
select 'Aberturas', 'aberturas', 'Instalaciones de aberturas'
 where not exists (select 1 from empresas);

-- ---------- Empresa de cada fila ----------
do $$
declare t text; e1 uuid;
begin
  select id into e1 from empresas order by creada_en limit 1;
  foreach t in array array['perfiles','obras','tipos_trabajo','categorias_gasto','trabajadores',
                           'jornadas','gastos','adelantos','cobros','pagos','permisos_rol'] loop
    execute format('alter table %I add column if not exists empresa_id uuid references empresas(id)', t);
    execute format('update %I set empresa_id = %L where empresa_id is null', t, e1);
  end loop;
end $$;
-- El creador no pertenece a ninguna empresa
update perfiles set empresa_id = null where creador;

-- ¿Cuál es mi empresa? Solo si está activa y no venció.
create or replace function mi_empresa() returns uuid
language sql stable security definer set search_path = public as $$
  select p.empresa_id from perfiles p join empresas e on e.id = p.empresa_id
   where p.id = auth.uid() and e.activa and (e.vence is null or e.vence >= current_date)
$$;

-- Al cargar algo, se guarda solo con la empresa de quien carga
do $$
declare t text;
begin
  foreach t in array array['obras','tipos_trabajo','categorias_gasto','trabajadores',
                           'jornadas','gastos','adelantos','cobros','pagos','permisos_rol'] loop
    execute format('alter table %I alter column empresa_id set default mi_empresa()', t);
    execute format('alter table %I alter column empresa_id set not null', t);
  end loop;
end $$;

-- Nombres únicos por empresa (antes eran únicos en toda la base)
alter table tipos_trabajo    drop constraint if exists tipos_trabajo_nombre_key;
alter table categorias_gasto drop constraint if exists categorias_gasto_nombre_key;
create unique index if not exists tipos_trabajo_empresa_nombre    on tipos_trabajo (empresa_id, nombre);
create unique index if not exists categorias_gasto_empresa_nombre on categorias_gasto (empresa_id, nombre);
alter table permisos_rol drop constraint if exists permisos_rol_pkey;
alter table permisos_rol add primary key (empresa_id, rol, permiso);

-- ---------- Regla de oro: cada empresa ve solo lo suyo ----------
-- Políticas "restrictivas": se suman a todas las demás, nadie las puede saltear.
do $$
declare t text;
begin
  foreach t in array array['obras','tipos_trabajo','categorias_gasto','trabajadores',
                           'jornadas','gastos','adelantos','cobros','pagos','permisos_rol'] loop
    execute format('drop policy if exists solo_mi_empresa on %I', t);
    execute format('create policy solo_mi_empresa on %I as restrictive for all to authenticated
                      using (empresa_id = mi_empresa()) with check (empresa_id = mi_empresa())', t);
  end loop;
end $$;
-- Perfiles: el propio siempre (para saber quién soy); el resto, solo los de mi empresa
drop policy if exists solo_mi_empresa on perfiles;
create policy solo_mi_empresa on perfiles as restrictive for all to authenticated
  using (id = auth.uid() or empresa_id = mi_empresa())
  with check (id = auth.uid() or empresa_id = mi_empresa());
-- Feriados: son nacionales y para todos; solo el creador los cambia
drop policy if exists admin_todo on feriados;
drop policy if exists creador_feriados on feriados;
create policy creador_feriados on feriados for all to authenticated using (es_creador()) with check (es_creador());

-- Permisos por rol: ahora miran la empresa
create or replace function puede(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from perfiles pf
     where pf.id = auth.uid() and pf.empresa_id = mi_empresa()
       and (pf.rol = 'admin'
            or exists (select 1 from permisos_rol r
                        where r.empresa_id = pf.empresa_id and r.rol = pf.rol::text and r.permiso = p))
  )
$$;

-- Una jornada solo puede ser de un trabajador de la misma empresa
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

-- Nombres de quién cargó cada cosa: solo los de mi empresa
create or replace view quienes with (security_invoker = false) as
  select id, nombre, rol from perfiles where empresa_id = mi_empresa();
revoke all on quienes from anon;
grant select on quienes to authenticated;

-- Fotos de comprobantes: las mías, o las de gastos que puedo ver (eso ya filtra por empresa)
drop policy if exists ver_comprobante on storage.objects;
create policy ver_comprobante on storage.objects for select to authenticated
  using (bucket_id = 'comprobantes'
         and ((storage.foldername(name))[1] = auth.uid()::text
              or exists (select 1 from public.gastos g where g.comprobante = storage.objects.name)));
drop policy if exists borrar_comprobante on storage.objects;
create policy borrar_comprobante on storage.objects for delete to authenticated
  using (bucket_id = 'comprobantes' and mi_rol() = 'admin'
         and exists (select 1 from public.gastos g where g.comprobante = storage.objects.name));

-- ---------- Empresas: quién ve qué ----------
drop policy if exists ver_mi_empresa on empresas;
create policy ver_mi_empresa on empresas for select to authenticated
  using (id = (select empresa_id from perfiles where id = auth.uid()) or es_creador());
drop policy if exists creador_empresas on empresas;
create policy creador_empresas on empresas for all to authenticated using (es_creador()) with check (es_creador());

-- El administrador de la empresa solo cambia la firma de WhatsApp
create or replace function cambiar_firma_empresa(p_firma text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() <> 'admin' or mi_empresa() is null then raise exception 'Solo el administrador de la empresa'; end if;
  update empresas set firma = nullif(trim(p_firma), '') where id = mi_empresa();
end $$;
revoke all on function cambiar_firma_empresa(text) from public;
grant execute on function cambiar_firma_empresa(text) to authenticated;

-- Para la pantalla de entrar: nombre de la empresa del enlace (sin iniciar sesión)
create or replace function empresa_publica(p_slug text)
returns table (nombre text, activa boolean)
language sql stable security definer set search_path = public as $$
  select e.nombre, e.activa and (e.vence is null or e.vence >= current_date)
    from empresas e where e.slug = lower(trim(p_slug))
$$;
revoke all on function empresa_publica(text) from public;
grant execute on function empresa_publica(text) to anon, authenticated;

-- Estado de mi empresa (para avisar si está pausada o vencida)
create or replace function mi_empresa_estado()
returns table (id uuid, nombre text, slug text, firma text, activa boolean, vence date)
language sql stable security definer set search_path = public as $$
  select e.id, e.nombre, e.slug, e.firma, e.activa and (e.vence is null or e.vence >= current_date), e.vence
    from perfiles p join empresas e on e.id = p.empresa_id where p.id = auth.uid()
$$;
revoke all on function mi_empresa_estado() from public;
grant execute on function mi_empresa_estado() to authenticated;

-- Panel del creador: lista de empresas con usuarios y última carga
create or replace function panel_empresas()
returns table (id uuid, nombre text, slug text, dueno_tel text, activa boolean, vence date,
               creada_en timestamptz, usuarios bigint, ultima_carga timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not es_creador() then raise exception 'Solo el creador de la app'; end if;
  return query
    select e.id, e.nombre, e.slug, e.dueno_tel, e.activa, e.vence, e.creada_en,
           (select count(*) from perfiles p where p.empresa_id = e.id),
           greatest((select max(g.cargado_en) from gastos g where g.empresa_id = e.id),
                    (select max(j.cargado_en) from jornadas j where j.empresa_id = e.id))
      from empresas e order by e.creada_en;
end $$;
revoke all on function panel_empresas() from public;
grant execute on function panel_empresas() to authenticated;

-- Empresa nueva: categorías, tipos de trabajo y permisos de entrada
create or replace function empresa_inicial() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into categorias_gasto (empresa_id, nombre)
    select new.id, x from unnest(array['Materiales','Herrajes','Combustible','Comida','Herramientas','Flete','Gastos médicos','Otros']) x;
  insert into tipos_trabajo (empresa_id, nombre)
    select new.id, x from unnest(array['Colocación','Mantenimiento','Arreglos generales']) x;
  insert into permisos_rol (empresa_id, rol, permiso) values
    (new.id,'encargado','cargar_gastos'), (new.id,'encargado','cargar_jornadas'), (new.id,'encargado','ver_informes'),
    (new.id,'encargado','ver_comprobantes'), (new.id,'encargado','aprobar'),
    (new.id,'asistente','cargar_gastos'), (new.id,'asistente','ver_comprobantes');
  return new;
end $$;
drop trigger if exists empresas_inicial on empresas;
create trigger empresas_inicial after insert on empresas for each row execute function empresa_inicial();

-- ---------- Crear cuenta ----------
-- Sin enlace: solo la primera cuenta de todas (el creador de la app).
-- Con el enlace de una empresa: el teléfono del dueño entra como administrador; el resto, como trabajador.
create or replace function crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
declare tel text; v_slug text; e empresas; ficha uuid; es_dueno boolean;
begin
  tel  := tel10(coalesce(new.raw_user_meta_data->>'telefono', split_part(new.email, '@', 1)));
  v_slug := lower(trim(coalesce(new.raw_user_meta_data->>'empresa', '')));
  if v_slug = '' then
    if exists (select 1 from perfiles where creador) then
      raise exception 'Para crear tu cuenta usá el enlace de tu empresa';
    end if;
    insert into perfiles (id, nombre, email, rol, telefono, admin_general, creador, empresa_id)
    values (new.id, coalesce(nullif(new.raw_user_meta_data->>'nombre', ''), split_part(new.email, '@', 1)),
            new.email, 'admin', tel, true, true, null);
    return new;
  end if;
  select * into e from empresas where empresas.slug = v_slug;
  if e.id is null then raise exception 'Ese enlace no corresponde a ninguna empresa'; end if;
  if not e.activa or (e.vence is not null and e.vence < current_date) then
    raise exception 'Esa empresa está pausada';
  end if;
  es_dueno := e.dueno_tel is not null and tel = tel10(e.dueno_tel);
  select id into ficha from trabajadores where empresa_id = e.id and tel10(telefono) = tel and tel is not null limit 1;
  insert into perfiles (id, nombre, email, rol, telefono, admin_general, trabajador_id, empresa_id)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'nombre', ''), split_part(new.email, '@', 1)),
          new.email, case when es_dueno then 'admin'::rol else 'trabajador'::rol end,
          tel, es_dueno, ficha, e.id);
  return new;
end $$;
drop trigger if exists perfiles_primer_creador on perfiles;

-- La ficha se vincula solo con cuentas de la misma empresa
create or replace function vincular_ficha() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tel10(new.telefono) is not null then
    update perfiles set trabajador_id = new.id
     where trabajador_id is null and rol = 'trabajador' and empresa_id = new.empresa_id
       and telefono = tel10(new.telefono);
  end if;
  return new;
end $$;

-- Usuario escrito: solo el dueño de cada empresa o el creador, y nadie se cambia de empresa desde la app
create or replace function proteger_admin_general() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;   -- cambios hechos desde el panel de Supabase
  if new.empresa_id is distinct from old.empresa_id and not es_creador() then
    raise exception 'No se puede cambiar de empresa desde la app';
  end if;
  if new.admin_general is distinct from old.admin_general and not es_creador() then
    raise exception 'Solo el creador de la app puede cambiar esto';
  end if;
  if new.alias is distinct from old.alias and new.id <> auth.uid() and not es_creador() then
    raise exception 'Cada uno elige su propio usuario';
  end if;
  if old.admin_general and new.rol <> 'admin' then
    raise exception 'El dueño de la empresa no puede dejar de ser administrador';
  end if;
  if new.alias is not null and not new.admin_general then
    raise exception 'Solo el dueño de la empresa puede tener usuario escrito';
  end if;
  return new;
end $$;
