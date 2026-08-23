-- =====================================================================
--  Mini WMS + Órdenes  ·  0005 · Desactivación (reversa) de movimientos
-- ---------------------------------------------------------------------
--  CONFLICTO IDENTIFICADO Y CÓMO SE RESUELVE
--
--  Se pidió "desactivar un movimiento con soft-delete". El modelo actual
--  declara la bitácora ESTRICTAMENTE de solo inserción:
--    · trg_tbl_movimientos_inventario__inmutable bloquea UPDATE y DELETE
--    · trg_..._sin_truncate bloquea TRUNCATE
--    · 0003_permisos revoca INSERT/UPDATE/DELETE al rol de la aplicación
--
--  Poner un `es_activo` mutable en la bitácora destruiría justo la garantía
--  que la hace confiable, y sería la "lógica paralela" que se pidió evitar.
--
--  La forma correcta en un libro de movimientos es la misma que en
--  contabilidad: NO se borra ni se edita el asiento, se registra un asiento
--  de REVERSA con el signo contrario. Con eso:
--    · el movimiento original queda intacto, bit a bit;
--    · la existencia se recalcula sola, porque la reversa pasa por el mismo
--      trigger que cualquier otro movimiento;
--    · sum(delta_fisica) sigue reconstruyendo cantidad_fisica;
--    · "está desactivado" se DERIVA de la existencia de su reversa, no de
--      una bandera que alguien pueda cambiar.
--
--  LÍMITES QUE ESTO IMPONE, y son correctos:
--    1. No se puede revertir un movimiento de ORDEN (RESERVA, EMBARQUE,
--       LIBERACION). Revertir un embarque dejaría la orden diciendo ENVIADA
--       sobre inventario que volvió: la vía es cancelar la orden.
--    2. No se puede revertir si el resultado dejaría existencia negativa o
--       por debajo de lo reservado. El ejemplo del enunciado
--       (+10, -3, existencia 7; revertir el +10) cae aquí: daría -3. Se
--       rechaza con WM002 en vez de corromper el inventario.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. La reversa es un tipo de movimiento más
-- ---------------------------------------------------------------------
alter table wms.tbl_movimientos_inventario
  drop constraint ck_tbl_movimientos_inventario__tipo,
  add  constraint ck_tbl_movimientos_inventario__tipo check (tipo_movimiento in
       ('ENTRADA','SALIDA','AJUSTE','RESERVA','LIBERACION','EMBARQUE','IMPORTACION','REVERSA'));

alter table wms.tbl_movimientos_inventario
  add column movimiento_revertido_id bigint,
  add constraint fk_tbl_movimientos_inventario__revertido
      foreign key (movimiento_revertido_id)
      references wms.tbl_movimientos_inventario (id) on delete restrict,
  -- Una reversa apunta a un original; cualquier otro movimiento, a nada.
  add constraint ck_tbl_movimientos_inventario__reversa check (
      (tipo_movimiento = 'REVERSA') = (movimiento_revertido_id is not null)),
  add constraint ck_tbl_movimientos_inventario__no_autoreversa check (
      movimiento_revertido_id is distinct from id);

-- Barrera del motor contra la doble desactivación: un movimiento solo puede
-- ser revertido UNA vez, pase lo que pase en la capa de aplicación.
create unique index ux_tbl_movimientos_inventario__reversa_unica
  on wms.tbl_movimientos_inventario (movimiento_revertido_id)
  where movimiento_revertido_id is not null;

comment on column wms.tbl_movimientos_inventario.movimiento_revertido_id is
  'Movimiento que esta reversa anula. La bitácora sigue siendo de solo inserción: desactivar es registrar el asiento contrario, nunca editar ni borrar el original.';

-- ---------------------------------------------------------------------
--  2. El trigger de bitácora propaga el enlace de reversa
-- ---------------------------------------------------------------------
create or replace function wms.fn_registrar_movimiento_inventario()
returns trigger language plpgsql as $$
declare v_df int; v_dr int; v_usuario bigint; v_operacion text; v_revertido bigint;
begin
  if tg_op = 'INSERT' then
     v_df := new.cantidad_fisica;                          v_dr := new.cantidad_reservada;
  else
     v_df := new.cantidad_fisica    - old.cantidad_fisica;
     v_dr := new.cantidad_reservada - old.cantidad_reservada;
  end if;

  if v_df = 0 and v_dr = 0 then return null; end if;

  v_usuario := nullif(current_setting('wms.ctx_usuario_id', true), '')::bigint;
  if v_usuario is null then
     raise exception 'No hay usuario en contexto: toda mutación de inventario debe ser atribuible'
       using errcode = 'WM014';
  end if;

  v_operacion := nullif(current_setting('wms.ctx_id_operacion', true), '');
  if v_operacion is null then
     raise exception 'No hay id_operacion en contexto: ninguna mutación de inventario puede quedar fuera del control de idempotencia'
       using errcode = 'WM012';
  end if;

  v_revertido := nullif(current_setting('wms.ctx_movimiento_revertido_id', true), '')::bigint;

  insert into wms.tbl_movimientos_inventario (
      producto_id, almacen_id, tipo_movimiento,
      delta_fisica, fisica_antes, fisica_despues,
      delta_reservada, reservada_antes, reservada_despues,
      tipo_origen, orden_id, lote_importacion_id,
      id_operacion, motivo, usuario_id, movimiento_revertido_id)
  values (
      new.producto_id, new.almacen_id,
      coalesce(nullif(current_setting('wms.ctx_tipo_movimiento', true), ''),
               case when v_df > 0 then 'ENTRADA'
                    when v_df < 0 then 'SALIDA'
                    when v_dr > 0 then 'RESERVA'
                    else 'LIBERACION' end),
      v_df, coalesce(old.cantidad_fisica, 0),    new.cantidad_fisica,
      v_dr, coalesce(old.cantidad_reservada, 0), new.cantidad_reservada,
      coalesce(nullif(current_setting('wms.ctx_tipo_origen', true), ''), 'MANUAL'),
      nullif(current_setting('wms.ctx_orden_id', true), '')::bigint,
      nullif(current_setting('wms.ctx_lote_id',  true), '')::bigint,
      v_operacion,
      nullif(current_setting('wms.ctx_motivo', true), ''),
      v_usuario, v_revertido);
  return null;
end $$;

create or replace function wms.fn_limpiar_contexto_movimiento()
returns void language plpgsql as $$
begin
  perform set_config('wms.ctx_tipo_movimiento', '', true);
  perform set_config('wms.ctx_tipo_origen',     '', true);
  perform set_config('wms.ctx_orden_id',        '', true);
  perform set_config('wms.ctx_lote_id',         '', true);
  perform set_config('wms.ctx_id_operacion',    '', true);
  perform set_config('wms.ctx_motivo',          '', true);
  perform set_config('wms.ctx_movimiento_revertido_id', '', true);
  -- wms.ctx_usuario_id NO se limpia: identifica la sesión completa.
end $$;

-- ---------------------------------------------------------------------
--  3. La primitiva de reversa
-- ---------------------------------------------------------------------
-- SOLO el usuario 1 (SISTEMA) puede ejecutarla. La restricción vive aquí,
-- en el motor, no en el frontend: ocultar un botón no es una autorización.
create or replace function wms.fn_revertir_movimiento(
  p_movimiento_id bigint, p_usuario_id bigint, p_id_operacion text, p_motivo text)
returns wms.tbl_movimientos_inventario language plpgsql as $$
declare
  v_orig wms.tbl_movimientos_inventario;
  v_inv  wms.tbl_inventario;
  v_nuevo wms.tbl_movimientos_inventario;
begin
  if p_usuario_id is distinct from 1 then
     raise exception 'Solo el usuario SISTEMA puede desactivar movimientos'
       using errcode = 'WM018';
  end if;
  if p_motivo is null or btrim(p_motivo) = '' then
     raise exception 'Desactivar un movimiento exige un motivo' using errcode = 'WM012';
  end if;

  -- FOR UPDATE sobre el original: serializa dos intentos simultáneos sin
  -- modificarlo. El lock es de fila, no una escritura.
  select * into v_orig from wms.tbl_movimientos_inventario
   where id = p_movimiento_id for update;
  if not found then
     raise exception 'El movimiento % no existe', p_movimiento_id using errcode = 'P0002';
  end if;

  if v_orig.tipo_movimiento = 'REVERSA' then
     raise exception 'Una reversa no se revierte: desactivaría la corrección, no el error'
       using errcode = 'WM019';
  end if;
  if v_orig.tipo_origen = 'ORDEN' then
     raise exception 'Este movimiento pertenece a la orden %; la vía es cancelar la orden, no revertir su movimiento',
       v_orig.orden_id using errcode = 'WM019';
  end if;
  if exists (select 1 from wms.tbl_movimientos_inventario
              where movimiento_revertido_id = p_movimiento_id) then
     raise exception 'El movimiento % ya está desactivado', p_movimiento_id using errcode = 'WM019';
  end if;

  perform set_config('wms.ctx_movimiento_revertido_id', p_movimiento_id::text, true);
  perform wms.fn_fijar_contexto_movimiento(
    'REVERSA', v_orig.tipo_origen, null, null, p_id_operacion, p_motivo, p_usuario_id);

  -- Se aplica el signo contrario. Los CHECK de tbl_inventario son la última
  -- red, pero la guardia explícita da un error de negocio legible.
  update wms.tbl_inventario
     set cantidad_fisica      = cantidad_fisica    - v_orig.delta_fisica,
         cantidad_reservada   = cantidad_reservada - v_orig.delta_reservada,
         version_concurrencia = version_concurrencia + 1,
         actualizado_en       = now()
   where producto_id = v_orig.producto_id and almacen_id = v_orig.almacen_id
     and cantidad_fisica    - v_orig.delta_fisica >= 0
     and cantidad_reservada - v_orig.delta_reservada >= 0
     and cantidad_fisica    - v_orig.delta_fisica
         >= cantidad_reservada - v_orig.delta_reservada
  returning * into v_inv;

  if not found then
     select * into v_inv from wms.tbl_inventario
      where producto_id = v_orig.producto_id and almacen_id = v_orig.almacen_id;
     raise exception
       'Revertir % dejaría la existencia en % (hay % reservadas): las unidades ya se consumieron',
       p_movimiento_id, v_inv.cantidad_fisica - v_orig.delta_fisica, v_inv.cantidad_reservada
       using errcode = 'WM002';
  end if;

  select * into v_nuevo from wms.tbl_movimientos_inventario
   where movimiento_revertido_id = p_movimiento_id;

  perform wms.fn_limpiar_contexto_movimiento();
  return v_nuevo;
end $$;

comment on function wms.fn_revertir_movimiento is
  'Desactiva un movimiento registrando su asiento contrario. El original nunca se toca. Restringida al usuario 1 (SISTEMA) en el propio motor.';

-- ---------------------------------------------------------------------
--  4. El estado de desactivación se DERIVA, no se almacena
-- ---------------------------------------------------------------------
drop view if exists wms.vw_movimientos_detalle;
create view wms.vw_movimientos_detalle as
select m.id, m.uuid_movimiento, m.creado_en, m.tipo_movimiento, m.tipo_origen,
       p.sku    as producto_sku, p.nombre as producto_nombre, p.estatus as producto_estatus,
       a.codigo as almacen_codigo, a.es_activo as almacen_vigente,
       m.delta_fisica, m.fisica_antes, m.fisica_despues,
       m.delta_reservada, m.reservada_antes, m.reservada_despues,
       case
         when rev.id is not null                                         then 'DESACTIVADO'
         when m.tipo_movimiento = 'RESERVA' and o.estatus = 'CANCELADA'  then 'COMPENSADO'
         when m.tipo_movimiento = 'RESERVA' and o.estatus = 'ENVIADA'    then 'CONSUMIDO'
         else 'APLICADO'
       end as estado,
       o.folio  as orden_folio, o.estatus as orden_estatus, cl.nombre as cliente_nombre,
       m.lote_importacion_id, l.nombre_archivo as lote_archivo,
       m.id_operacion, m.motivo,
       u.id as usuario_id, u.codigo as usuario_codigo, u.nombre as usuario_nombre,
       u.es_activo as usuario_vigente,
       m.producto_id, m.almacen_id,
       -- Desactivación derivada de la existencia de la reversa.
       (rev.id is not null)      as esta_desactivado,
       rev.id                    as reversa_id,
       rev.creado_en             as desactivado_en,
       ru.nombre                 as desactivado_por_nombre,
       rev.motivo                as motivo_desactivacion,
       m.movimiento_revertido_id,
       -- Si este renglón ES una reversa, a qué movimiento anula.
       (m.tipo_movimiento = 'REVERSA') as es_reversa
  from wms.tbl_movimientos_inventario m
  join wms.cat_productos p  on p.id  = m.producto_id
  join wms.cat_almacenes a  on a.id  = m.almacen_id
  join wms.cat_usuarios  u  on u.id  = m.usuario_id
  left join wms.tbl_movimientos_inventario rev on rev.movimiento_revertido_id = m.id
  left join wms.cat_usuarios  ru on ru.id = rev.usuario_id
  left join wms.tbl_ordenes           o  on o.id  = m.orden_id
  left join wms.cat_clientes          cl on cl.id = o.cliente_id
  left join wms.tbl_lotes_importacion l  on l.id  = m.lote_importacion_id;

-- La demanda no debe contar embarques que luego se revirtieron.
create or replace function wms.fn_productos_mayor_demanda(
  p_dias integer default 30, p_limite integer default 10)
returns table (
  posicion            bigint,
  producto_id         bigint,
  producto_sku        text,
  producto_nombre     text,
  categoria_nombre    text,
  unidades_demandadas bigint,
  embarques           bigint,
  unidades_comprometidas bigint,
  ultima_salida_en    timestamptz
) language sql stable as $$
  with embarcado as (
    select m.producto_id,
           sum(abs(m.delta_fisica))::bigint as unidades,
           count(*)::bigint                 as embarques,
           max(m.creado_en)                 as ultima
      from wms.tbl_movimientos_inventario m
     where m.tipo_movimiento = 'EMBARQUE'
       and m.creado_en >= now() - make_interval(days => greatest(p_dias, 1))
       and not exists (select 1 from wms.tbl_movimientos_inventario r
                        where r.movimiento_revertido_id = m.id)
     group by m.producto_id
  ),
  comprometido as (
    select i.producto_id, sum(i.cantidad_reservada)::bigint as reservado
      from wms.tbl_inventario i group by i.producto_id
  )
  select row_number() over (order by e.unidades desc, p.sku) as posicion,
         p.id, p.sku, p.nombre, c.nombre,
         e.unidades, e.embarques,
         coalesce(r.reservado, 0), e.ultima
    from embarcado e
    join wms.cat_productos  p on p.id = e.producto_id
    join wms.cat_categorias c on c.id = p.categoria_id
    left join comprometido  r on r.producto_id = p.id
   order by e.unidades desc, p.sku
   limit greatest(p_limite, 1);
$$;
