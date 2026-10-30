-- =====================================================================
-- Gastos de Obra · parte 6: panel de control del creador de la app
-- Correr en el SQL Editor DESPUÉS de las partes 1 a 5. Se puede volver a correr.
-- - "creador" es quien hizo la app (BR Soluciones). Solo se marca desde acá,
--   nunca desde la app.
-- - config_app guarda los textos y columnas que el creador edita desde el panel.
--   La puede leer cualquiera (la pantalla de entrar muestra el slogan),
--   pero solo el creador la cambia.
-- =====================================================================

alter table perfiles add column if not exists creador boolean not null default false;

create or replace function es_creador() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select creador from perfiles where id = auth.uid()), false)
$$;

-- Nadie puede marcarse ni desmarcarse como creador desde la app
create or replace function proteger_creador() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.creador is distinct from old.creador then
    raise exception 'Esto solo se cambia desde el panel de Supabase';
  end if;
  return new;
end $$;
drop trigger if exists perfiles_creador on perfiles;
create trigger perfiles_creador before update on perfiles
  for each row execute function proteger_creador();

create table if not exists config_app (
  clave      text primary key,
  valor      jsonb not null,
  cambiado_por uuid default auth.uid(),
  cambiado_en  timestamptz not null default now()
);
alter table config_app enable row level security;
drop policy if exists ver_config on config_app;
create policy ver_config on config_app for select to anon, authenticated using (true);
drop policy if exists creador_config on config_app;
create policy creador_config on config_app for all to authenticated
  using (es_creador()) with check (es_creador());
grant select on config_app to anon, authenticated;
grant insert, update, delete on config_app to authenticated;

-- El administrador general actual pasa a ser el creador (solo si todavía no hay uno)
update perfiles set creador = true
 where admin_general and not exists (select 1 from perfiles where creador);

-- Si todavía no había cuentas, la primera que se cree (el admin general) queda como creador
create or replace function primer_creador() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.admin_general and not exists (select 1 from perfiles where creador) then
    new.creador := true;
  end if;
  return new;
end $$;
drop trigger if exists perfiles_primer_creador on perfiles;
create trigger perfiles_primer_creador before insert on perfiles
  for each row execute function primer_creador();
