-- =====================================================================
-- Gastos de Obra · base de datos (Supabase / PostgreSQL)
-- Cómo usarlo: en Supabase abrí "SQL Editor", pegá todo este archivo y
-- tocá "Run". Se puede correr una sola vez en un proyecto nuevo.
-- =====================================================================

-- ---------- Roles y perfiles ----------
create type rol as enum ('admin', 'encargado', 'trabajador');

-- Un perfil por persona que entra a la app (vos, encargados, trabajadores)
create table perfiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nombre      text not null,
  rol         rol  not null default 'trabajador',
  trabajador_id uuid,                 -- si es trabajador, a qué ficha corresponde
  creado_en   timestamptz not null default now()
);

-- ---------- Configuración ----------
create table obras (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,
  cliente   text,                      -- empresa o cliente que paga
  direccion text,
  activa    boolean not null default true,
  creado_en timestamptz not null default now()
);

create table tipos_trabajo (           -- Colocación, Limpieza, Mantenimiento... (se agregan)
  id     uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activo boolean not null default true
);

create table categorias_gasto (        -- Materiales, Combustible, Gastos médicos... (se agregan)
  id     uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activa boolean not null default true
);

create type modo_extra as enum ('igual', 'porcentaje', 'fijo');
create type frecuencia_pago as enum ('dia', 'semana');

create table trabajadores (
  id              uuid primary key default gen_random_uuid(),
  nombre          text not null,
  telefono        text,                         -- WhatsApp con código de país, ej 5493411234567
  precio_jornada  numeric(12,2) not null,
  horas_jornada   numeric(4,2)  not null default 8,
  extra_modo      modo_extra    not null default 'igual',
  extra_porcentaje numeric(6,2) not null default 0,   -- si modo = porcentaje
  extra_fijo      numeric(12,2) not null default 0,   -- si modo = fijo
  recargo_sabado  numeric(6,2)  not null default 0,   -- % sobre la hora extra
  recargo_domingo numeric(6,2)  not null default 0,   -- % sobre la hora extra (domingo y feriado)
  frecuencia      frecuencia_pago not null default 'semana',
  activo          boolean not null default true,
  creado_en       timestamptz not null default now()
);

alter table perfiles
  add constraint perfiles_trabajador_fk foreign key (trabajador_id) references trabajadores(id) on delete set null;

create table feriados (
  fecha  date primary key,
  motivo text
);

-- ---------- Movimientos ----------
create type estado_carga as enum ('pendiente', 'aprobado', 'rechazado');
create type tipo_dia as enum ('habil', 'sabado', 'domingo', 'feriado');

create table jornadas (
  id             uuid primary key default gen_random_uuid(),
  trabajador_id  uuid not null references trabajadores(id),
  obra_id        uuid references obras(id),
  fecha          date not null,
  dia            tipo_dia not null default 'habil',
  horas_extra    numeric(5,2) not null default 0,
  -- se guardan los valores del momento: si después cambia el precio, esto no se recalcula
  precio_jornada numeric(12,2) not null,
  valor_hora_extra numeric(12,2) not null,
  total          numeric(12,2) generated always as (precio_jornada + horas_extra * valor_hora_extra) stored,
  estado         estado_carga not null default 'aprobado',
  pago_id        uuid,                           -- se completa al liquidar
  cargado_por    uuid not null default auth.uid() references perfiles(id),
  cargado_en     timestamptz not null default now(),
  id_local       text unique                     -- id generado en el celular (evita duplicados al sincronizar)
);

create table gastos (
  id            uuid primary key default gen_random_uuid(),
  obra_id       uuid references obras(id),       -- vacío = gasto general
  categoria_id  uuid not null references categorias_gasto(id),
  monto         numeric(12,2) not null check (monto > 0),
  fecha         date not null default current_date,
  nota          text,
  comprobante   text,                            -- ruta de la foto en el almacenamiento
  trabajador_id uuid references trabajadores(id),-- si lo pagó un trabajador de su bolsillo
  estado        estado_carga not null default 'aprobado',
  cargado_por   uuid not null default auth.uid() references perfiles(id),
  cargado_en    timestamptz not null default now(),
  id_local      text unique
);

create table adelantos (
  id            uuid primary key default gen_random_uuid(),
  trabajador_id uuid not null references trabajadores(id),
  monto         numeric(12,2) not null check (monto > 0),
  fecha         date not null default current_date,
  motivo        text,
  cargado_por   uuid not null default auth.uid() references perfiles(id),
  cargado_en    timestamptz not null default now(),
  id_local      text unique
);

create type forma_cobro as enum ('m2', 'hora', 'total');

create table cobros (
  id              uuid primary key default gen_random_uuid(),
  obra_id         uuid not null references obras(id),
  tipo_trabajo_id uuid references tipos_trabajo(id),
  forma           forma_cobro not null,
  cantidad        numeric(12,2),                 -- m² u horas
  precio_unitario numeric(12,2),
  monto           numeric(12,2) not null check (monto > 0),
  fecha           date not null default current_date,
  cobrado         boolean not null default false,-- si la empresa ya te pagó
  nota            text,
  cargado_por     uuid not null default auth.uid() references perfiles(id),
  cargado_en      timestamptz not null default now(),
  id_local        text unique
);

create type estado_pago as enum ('enviado', 'confirmado');

create table pagos (
  id                 uuid primary key default gen_random_uuid(),
  trabajador_id      uuid not null references trabajadores(id),
  desde              date not null,
  hasta              date not null,
  bruto              numeric(12,2) not null,
  descuento_adelanto numeric(12,2) not null default 0,
  neto               numeric(12,2) generated always as (bruto - descuento_adelanto) stored,
  mensaje            text,                       -- el texto que se mandó por WhatsApp
  codigo             text not null unique default substr(md5(random()::text), 1, 10),
  estado             estado_pago not null default 'enviado',
  confirmado_en      timestamptz,
  cargado_por        uuid not null default auth.uid() references perfiles(id),
  cargado_en         timestamptz not null default now()
);

alter table jornadas add constraint jornadas_pago_fk foreign key (pago_id) references pagos(id) on delete set null;

-- Saldo de adelantos de cada trabajador (cuenta corriente)
create view saldo_adelantos with (security_invoker = true) as
select t.id as trabajador_id, t.nombre,
       coalesce((select sum(monto) from adelantos a where a.trabajador_id = t.id), 0)
     - coalesce((select sum(descuento_adelanto) from pagos p where p.trabajador_id = t.id), 0) as saldo
from trabajadores t;

-- ---------- Ayudas para permisos ----------
create function mi_rol() returns rol
language sql stable security definer set search_path = public as
$$ select rol from perfiles where id = auth.uid() $$;

create function mi_trabajador() returns uuid
language sql stable security definer set search_path = public as
$$ select trabajador_id from perfiles where id = auth.uid() $$;

-- Lo que carga un trabajador queda pendiente hasta que el admin lo apruebe
create function estado_segun_rol() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() = 'trabajador' then new.estado := 'pendiente'; end if;
  return new;
end $$;
create trigger jornadas_estado before insert on jornadas for each row execute function estado_segun_rol();
create trigger gastos_estado   before insert on gastos   for each row execute function estado_segun_rol();

-- El servidor calcula el tipo de día y los valores de la jornada con la ficha del trabajador
-- (así nadie puede cargar un precio distinto desde el celular)
create function calcular_jornada() returns trigger
language plpgsql security definer set search_path = public as $$
declare t trabajadores; vh numeric; ve numeric; rec numeric;
begin
  select * into t from trabajadores where id = new.trabajador_id;
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
create trigger jornadas_calculo before insert on jornadas for each row execute function calcular_jornada();

-- ---------- Permisos por rol (Row Level Security) ----------
alter table perfiles         enable row level security;
alter table obras            enable row level security;
alter table tipos_trabajo    enable row level security;
alter table categorias_gasto enable row level security;
alter table trabajadores     enable row level security;
alter table feriados         enable row level security;
alter table jornadas         enable row level security;
alter table gastos           enable row level security;
alter table adelantos        enable row level security;
alter table cobros           enable row level security;
alter table pagos            enable row level security;

-- Admin: todo
create policy admin_todo on perfiles         for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on obras            for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on tipos_trabajo    for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on categorias_gasto for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on trabajadores     for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on feriados         for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on jornadas         for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on gastos           for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on adelantos        for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on cobros           for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_todo on pagos            for all using (mi_rol() = 'admin') with check (mi_rol() = 'admin');

-- Todos los que entran ven su propio perfil y las listas de configuración
create policy ver_mi_perfil on perfiles for select using (id = auth.uid());
create policy ver_obras        on obras            for select using (auth.uid() is not null);
create policy ver_tipos        on tipos_trabajo    for select using (auth.uid() is not null);
create policy ver_categorias   on categorias_gasto for select using (auth.uid() is not null);
create policy ver_feriados     on feriados         for select using (auth.uid() is not null);

-- Encargado: carga y ve jornadas y gastos de todos; ve trabajadores; no ve cobros ni pagos
create policy enc_trab_ver   on trabajadores for select using (mi_rol() = 'encargado');
create policy enc_jor_ver    on jornadas for select using (mi_rol() = 'encargado');
create policy enc_jor_cargar on jornadas for insert with check (mi_rol() = 'encargado' and cargado_por = auth.uid());
create policy enc_gas_ver    on gastos   for select using (mi_rol() = 'encargado');
create policy enc_gas_cargar on gastos   for insert with check (mi_rol() = 'encargado' and cargado_por = auth.uid());

-- Trabajador: solo lo suyo
create policy tra_ficha     on trabajadores for select using (id = mi_trabajador());
create policy tra_jor_ver   on jornadas  for select using (trabajador_id = mi_trabajador());
create policy tra_jor_carga on jornadas  for insert with check (trabajador_id = mi_trabajador() and cargado_por = auth.uid());
create policy tra_gas_ver   on gastos    for select using (cargado_por = auth.uid());
create policy tra_gas_carga on gastos    for insert with check (cargado_por = auth.uid() and trabajador_id = mi_trabajador());
create policy tra_ade_ver   on adelantos for select using (trabajador_id = mi_trabajador());
create policy tra_pag_ver   on pagos     for select using (trabajador_id = mi_trabajador());

-- ---------- Confirmación de pago desde el enlace de WhatsApp ----------
-- Se llama sin iniciar sesión, solo con el código del enlace. Registra fecha y hora.
create function confirmar_pago(p_codigo text) returns table (trabajador text, neto numeric, confirmado_en timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  update pagos set estado = 'confirmado', confirmado_en = coalesce(pagos.confirmado_en, now())
   where codigo = p_codigo;
  return query
    select t.nombre, p.neto, p.confirmado_en
      from pagos p join trabajadores t on t.id = p.trabajador_id
     where p.codigo = p_codigo;
end $$;
revoke all on function confirmar_pago(text) from public;
grant execute on function confirmar_pago(text) to anon, authenticated;

-- ---------- Datos iniciales ----------
insert into tipos_trabajo (nombre) values
  ('Colocación de aberturas'), ('Limpieza de aberturas'), ('Arreglos generales'), ('Mantenimiento');

insert into categorias_gasto (nombre) values
  ('Materiales'), ('Herrajes'), ('Combustible'), ('Comida'), ('Herramientas'), ('Flete'), ('Gastos médicos'), ('Otros');

insert into feriados (fecha, motivo) values
  ('2026-01-01','Año nuevo'), ('2026-02-16','Carnaval'), ('2026-02-17','Carnaval'),
  ('2026-03-24','Día de la Memoria'), ('2026-04-02','Malvinas'), ('2026-04-03','Viernes Santo'),
  ('2026-05-01','Día del Trabajador'), ('2026-05-25','Revolución de Mayo'), ('2026-06-20','Día de la Bandera'),
  ('2026-07-09','Independencia'), ('2026-12-08','Inmaculada Concepción'), ('2026-12-25','Navidad');

-- ---------- Fotos de comprobantes ----------
-- Carpeta privada para las fotos. Cada uno sube a su carpeta; el admin y el encargado ven todas.
insert into storage.buckets (id, name, public) values ('comprobantes', 'comprobantes', false)
  on conflict do nothing;
create policy subir_comprobante on storage.objects for insert to authenticated
  with check (bucket_id = 'comprobantes' and (storage.foldername(name))[1] = auth.uid()::text);
create policy ver_comprobante on storage.objects for select to authenticated
  using (bucket_id = 'comprobantes' and ((storage.foldername(name))[1] = auth.uid()::text or mi_rol() in ('admin','encargado')));
