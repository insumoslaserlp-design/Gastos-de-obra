-- =====================================================================
-- Gastos de Obra · parte 3: entrar con teléfono
-- Correr en el SQL Editor DESPUÉS de esquema.sql y esquema-2-usuarios.sql.
-- - Todos entran con su número de teléfono y contraseña.
-- - Solo el administrador general puede, además, entrar con un usuario escrito.
-- - Si alguien crea su cuenta con el teléfono que tiene en su ficha de
--   trabajador, queda vinculado solo.
-- =====================================================================

alter table perfiles add column if not exists telefono text;
alter table perfiles add column if not exists alias text;
alter table perfiles add column if not exists admin_general boolean not null default false;
create unique index if not exists perfiles_alias_unico on perfiles (lower(alias)) where alias is not null;

-- Últimos 10 números (código de área + número, sin 0 ni 15 ni 549)
create or replace function tel10(t text) returns text
language sql immutable as $$
  select nullif(right(regexp_replace(coalesce(t, ''), '\D', '', 'g'), 10), '')
$$;

-- Al crear una cuenta: el primero es el administrador general; los demás se
-- vinculan con su ficha si el teléfono coincide.
create or replace function crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
declare primero boolean; tel text; ficha uuid;
begin
  primero := not exists (select 1 from perfiles);
  tel := tel10(coalesce(new.raw_user_meta_data->>'telefono', split_part(new.email, '@', 1)));
  select id into ficha from trabajadores where tel10(telefono) = tel and tel is not null limit 1;
  insert into perfiles (id, nombre, email, rol, telefono, admin_general, trabajador_id)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'nombre', ''), split_part(new.email, '@', 1)),
    new.email,
    case when primero then 'admin'::rol else 'trabajador'::rol end,
    tel,
    primero,
    case when primero then null else ficha end
  );
  return new;
end $$;

-- Si se carga o se cambia el teléfono de una ficha, se vincula con la cuenta que ya exista
create or replace function vincular_ficha() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tel10(new.telefono) is not null then
    update perfiles set trabajador_id = new.id
     where trabajador_id is null and rol = 'trabajador' and telefono = tel10(new.telefono);
  end if;
  return new;
end $$;
drop trigger if exists trabajadores_vincular on trabajadores;
create trigger trabajadores_vincular after insert or update of telefono on trabajadores
  for each row execute function vincular_ficha();

-- Solo el administrador general puede tocar el usuario escrito y quién es admin general,
-- y a él nadie le puede quitar el rol de administrador.
create or replace function proteger_admin_general() returns trigger
language plpgsql security definer set search_path = public as $$
declare yo_general boolean;
begin
  if auth.uid() is null then return new; end if;   -- cambios hechos desde el panel de Supabase
  select admin_general into yo_general from perfiles where id = auth.uid();
  if (new.alias is distinct from old.alias or new.admin_general is distinct from old.admin_general)
     and not coalesce(yo_general, false) then
    raise exception 'Solo el administrador general puede cambiar esto';
  end if;
  if old.admin_general and new.rol <> 'admin' then
    raise exception 'El administrador general no puede dejar de ser administrador';
  end if;
  if new.alias is not null and not new.admin_general then
    raise exception 'Solo el administrador general puede tener usuario escrito';
  end if;
  return new;
end $$;
drop trigger if exists perfiles_proteger on perfiles;
create trigger perfiles_proteger before update on perfiles
  for each row execute function proteger_admin_general();

-- Entrar con el usuario escrito: devuelve el identificador interno solo si es el admin general
create or replace function login_alias(p_alias text) returns text
language sql stable security definer set search_path = public as $$
  select email from perfiles
   where admin_general and alias is not null and lower(alias) = lower(trim(p_alias))
   limit 1
$$;
revoke all on function login_alias(text) from public;
grant execute on function login_alias(text) to anon, authenticated;

-- Si ya había una cuenta creada, la primera pasa a ser el administrador general
update perfiles set admin_general = true
 where id = (select id from perfiles where rol = 'admin' order by creado_en limit 1)
   and not exists (select 1 from perfiles where admin_general);
