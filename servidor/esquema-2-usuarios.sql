-- =====================================================================
-- Gastos de Obra · parte 2: usuarios
-- Correr en el SQL Editor DESPUÉS de esquema.sql (una sola vez).
-- La primera persona que se registra en la app queda como administrador.
-- Las siguientes entran como "trabajador" sin acceso a nada hasta que
-- el administrador les asigna su rol y su ficha desde la app.
-- =====================================================================

alter table perfiles add column if not exists email text;

create or replace function crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (id, nombre, email, rol)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'nombre', ''), split_part(new.email, '@', 1)),
    new.email,
    case when exists (select 1 from perfiles) then 'trabajador'::rol else 'admin'::rol end
  );
  return new;
end $$;

drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario after insert on auth.users
  for each row execute function crear_perfil();

-- Nombres de quién cargó cada cosa: todos los usuarios pueden ver nombre y rol de los demás
create or replace view quienes with (security_invoker = false) as
  select id, nombre, rol from perfiles;
revoke all on quienes from anon;
grant select on quienes to authenticated;
