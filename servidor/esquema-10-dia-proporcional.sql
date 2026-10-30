-- =====================================================================
-- Clarita · parte 10: un día con menos horas que la jornada se paga proporcional
-- Correr en el SQL Editor DESPUÉS de la parte 9. Se puede volver a correr.
-- Ej: jornada de 8 h a $40.000 → 4 h trabajadas = $20.000.
-- Si no se cargó el horario (horas vacías), se paga la jornada entera.
-- Solo vale para las jornadas que se carguen de ahora en adelante.
-- =====================================================================
create or replace function calcular_jornada() returns trigger
language plpgsql security definer set search_path = public as $$
declare t trabajadores; vh numeric; ve numeric; rec numeric; h numeric;
  minimo constant numeric := 0;   -- fracción mínima de la jornada que se paga (0 = sin mínimo)
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
  new.precio_jornada := t.precio_jornada;
  if new.horas is not null and new.horas > 0 and new.horas < t.horas_jornada then
    h := greatest(new.horas, t.horas_jornada * minimo);
    new.precio_jornada := round(t.precio_jornada * h / t.horas_jornada, 2);
    new.horas_extra    := 0;
  end if;
  new.valor_hora_extra := round(ve * (1 + rec / 100), 2);
  return new;
end $$;

-- Días cortos cargados antes de correr esta parte y que todavía no se pagaron:
-- se recalculan con el precio proporcional.
update jornadas j
   set precio_jornada = round(t.precio_jornada * j.horas / t.horas_jornada, 2),
       horas_extra    = 0
  from trabajadores t
 where t.id = j.trabajador_id
   and j.pago_id is null
   and coalesce(j.estado_dia, 'trabajado') = 'trabajado'
   and j.horas > 0 and j.horas < t.horas_jornada
   and j.precio_jornada = t.precio_jornada;
