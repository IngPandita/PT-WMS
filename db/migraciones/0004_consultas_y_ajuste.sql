-- =====================================================================
--  Mini WMS + Órdenes  ·  0004 · Búsqueda, ajuste absoluto e indicadores
-- ---------------------------------------------------------------------
--  Añade lo que las nuevas funcionalidades necesitan SIN cambiar reglas
--  existentes: búsqueda parcial de productos, ajuste manual a cantidad
--  objetivo, filtros de movimientos y dos indicadores nuevos.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. Búsqueda parcial de productos
-- ---------------------------------------------------------------------
-- ix_cat_productos__sku_prefijo usa text_pattern_ops, que solo sirve para
-- 'ELEC%'. La búsqueda del modal de órdenes es '%texto%', que ese índice no
-- puede resolver: hace falta un trigrama también sobre el SKU.
create index if not exists ix_cat_productos__sku_trgm
  on wms.cat_productos using gin (sku gin_trgm_ops);

comment on index wms.ix_cat_productos__sku_trgm is
  'Búsqueda por subcadena sobre el SKU. El índice text_pattern_ops solo cubre prefijos.';

-- ---------------------------------------------------------------------
--  2. Filtros de movimientos
-- ---------------------------------------------------------------------
-- La vista no exponía las llaves, solo sus etiquetas. Filtrar por SKU exigía
-- una subconsulta contra cat_productos por cada fila; filtrar por el
-- identificador real es más barato y, sobre todo, es lo correcto: el filtro
-- debe apuntar al producto, no al texto que se muestra.
create or replace view wms.vw_movimientos_detalle as
select m.id, m.uuid_movimiento, m.creado_en, m.tipo_movimiento, m.tipo_origen,
       p.sku    as producto_sku, p.nombre as producto_nombre, p.estatus as producto_estatus,
       a.codigo as almacen_codigo, a.es_activo as almacen_vigente,
       m.delta_fisica, m.fisica_antes, m.fisica_despues,
       m.delta_reservada, m.reservada_antes, m.reservada_despues,
       case
         when m.tipo_movimiento = 'RESERVA' and o.estatus = 'CANCELADA' then 'COMPENSADO'
         when m.tipo_movimiento = 'RESERVA' and o.estatus = 'ENVIADA'   then 'CONSUMIDO'
         else 'APLICADO'
       end as estado,
       o.folio  as orden_folio, o.estatus as orden_estatus, cl.nombre as cliente_nombre,
       m.lote_importacion_id, l.nombre_archivo as lote_archivo,
       m.id_operacion, m.motivo,
       u.id as usuario_id, u.codigo as usuario_codigo, u.nombre as usuario_nombre,
       u.es_activo as usuario_vigente,
       -- Columnas añadidas al final: CREATE OR REPLACE VIEW solo lo permite ahí.
       m.producto_id, m.almacen_id
  from wms.tbl_movimientos_inventario m
  join wms.cat_productos p  on p.id  = m.producto_id
  join wms.cat_almacenes a  on a.id  = m.almacen_id
  join wms.cat_usuarios  u  on u.id  = m.usuario_id
  left join wms.tbl_ordenes           o  on o.id  = m.orden_id
  left join wms.cat_clientes          cl on cl.id = o.cliente_id
  left join wms.tbl_lotes_importacion l  on l.id  = m.lote_importacion_id;

-- El indicador de demanda recorre un tipo concreto dentro de una ventana de
-- fechas; sin este índice sería un recorrido completo de la bitácora.
create index if not exists ix_tbl_movimientos_inventario__tipo_fecha
  on wms.tbl_movimientos_inventario (tipo_movimiento, creado_en desc);

-- ---------------------------------------------------------------------
--  3. Ajuste manual a cantidad OBJETIVO
-- ---------------------------------------------------------------------
-- El operador que hace un conteo físico piensa en "hay 15", no en "+5". Pero
-- convertir objetivo->delta en el cliente sería una condición de carrera: si
-- otro operador mueve el producto entre la lectura y el envío, el delta
-- calculado sobre un valor viejo aplicaría de más o de menos.
--
-- Por eso la conversión ocurre AQUÍ, dentro del UPDATE que ya toma el row
-- lock. El delta lo deduce el trigger de bitácora comparando OLD y NEW, así
-- que el movimiento registrado es exactamente el que ocurrió.
--
-- p_version_esperada sí es relevante en esta operación, al contrario que en
-- el ajuste por delta: escribir una cantidad ABSOLUTA sobre una lectura
-- obsoleta descarta en silencio lo que otro operador acaba de hacer.
create or replace function wms.fn_establecer_existencia(
  p_producto_id bigint, p_almacen_id bigint, p_objetivo integer,
  p_usuario_id bigint, p_id_operacion text,
  p_motivo text default null, p_version_esperada bigint default null
) returns wms.tbl_inventario language plpgsql as $$
declare v_row wms.tbl_inventario; v_actual wms.tbl_inventario;
begin
  if p_objetivo is null or p_objetivo < 0 then
     raise exception 'La existencia objetivo debe ser un entero no negativo'
       using errcode = 'WM012';
  end if;

  perform wms.fn_fijar_contexto_movimiento(
    'AJUSTE', 'AJUSTE_RAPIDO', null, null, p_id_operacion,
    coalesce(p_motivo, 'Ajuste manual de existencia'), p_usuario_id);

  insert into wms.tbl_inventario (producto_id, almacen_id)
  values (p_producto_id, p_almacen_id)
  on conflict (producto_id, almacen_id) do nothing;

  update wms.tbl_inventario
     set cantidad_fisica      = p_objetivo,
         version_concurrencia = version_concurrencia + 1,
         actualizado_en       = now()
   where producto_id = p_producto_id and almacen_id = p_almacen_id
     and (p_version_esperada is null or version_concurrencia = p_version_esperada)
     -- No se puede dejar la existencia por debajo de lo ya comprometido.
     and p_objetivo >= cantidad_reservada
  returning * into v_row;

  if not found then
     select * into v_actual from wms.tbl_inventario
      where producto_id = p_producto_id and almacen_id = p_almacen_id;

     if p_version_esperada is not null
        and v_actual.version_concurrencia is distinct from p_version_esperada then
        raise exception 'La existencia cambió desde que se cargó la pantalla (versión % vs %)',
          p_version_esperada, v_actual.version_concurrencia using errcode = 'WM008';
     end if;

     raise exception 'No puede quedar en % : hay % unidades reservadas',
       p_objetivo, v_actual.cantidad_reservada using errcode = 'WM002';
  end if;

  perform wms.fn_limpiar_contexto_movimiento();
  return v_row;
end $$;

comment on function wms.fn_establecer_existencia is
  'Ajuste manual a cantidad objetivo. La conversión objetivo->delta ocurre bajo el row lock; el movimiento AJUSTE lo escribe el trigger de bitácora con el delta real.';

-- ---------------------------------------------------------------------
--  4. Indicador: productos con mayor demanda
-- ---------------------------------------------------------------------
-- DEFINICIÓN, tomada del modelo y no inventada:
--   EMBARQUE  lo produce únicamente fn_enviar_orden -> es consumo real de un
--             cliente. Es la demanda ATENDIDA.
--   RESERVA   lo produce fn_confirmar_orden -> demanda comprometida que aún
--             no sale. Se reporta aparte, no se suma.
--   SALIDA    es una salida manual (merma, corrección). NO es demanda de
--             cliente y queda fuera a propósito.
--   LIBERACION revierte una reserva cancelada: tampoco es demanda.
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

comment on function wms.fn_productos_mayor_demanda is
  'Demanda = unidades EMBARCADAS en la ventana. Se excluyen SALIDA (merma/corrección) y RESERVA (comprometida, aún no consumida); la reserva vigente se reporta en columna aparte.';

-- ---------------------------------------------------------------------
--  5. Indicador: existencia insuficiente
-- ---------------------------------------------------------------------
-- El modelo YA tiene el umbral: tbl_inventario.cantidad_minima. No se inventa
-- ningún campo.
--
-- El faltante se calcula contra cantidad_DISPONIBLE, no contra la física: las
-- unidades reservadas ya están comprometidas con órdenes confirmadas y no
-- pueden cubrir demanda nueva. Se exponen las tres cantidades para que la
-- diferencia con es_existencia_baja —que usa la física, como disparador
-- clásico de reorden— sea visible y no una discrepancia silenciosa.
create or replace view wms.vw_existencia_insuficiente as
select i.producto_id, i.almacen_id,
       p.sku    as producto_sku,
       p.nombre as producto_nombre,
       p.estatus as producto_estatus,
       c.nombre as categoria_nombre,
       a.codigo as almacen_codigo,
       p.sku || '@' || a.codigo as localizador,
       i.cantidad_fisica,
       i.cantidad_reservada,
       i.cantidad_disponible,
       i.cantidad_minima,
       (i.cantidad_minima - i.cantidad_disponible)          as faltante,
       (i.cantidad_fisica <= i.cantidad_minima)             as es_existencia_baja,
       round(100.0 * i.cantidad_disponible
             / nullif(i.cantidad_minima, 0), 1)             as cobertura_pct,
       p.precio_unitario * (i.cantidad_minima - i.cantidad_disponible) as costo_reposicion
  from wms.tbl_inventario i
  join wms.cat_productos  p on p.id = i.producto_id
  join wms.cat_categorias c on c.id = p.categoria_id
  join wms.cat_almacenes  a on a.id = i.almacen_id
 where i.cantidad_minima > 0
   and i.cantidad_disponible < i.cantidad_minima
   and p.estatus = 'ACTIVO'      -- un producto descontinuado no se repone
   and a.es_activo;              -- ni un almacén dado de baja

comment on view wms.vw_existencia_insuficiente is
  'Faltante frente a cantidad_minima medido sobre la existencia DISPONIBLE: lo reservado ya está comprometido. Excluye productos descontinuados y almacenes inactivos.';

-- El índice parcial existente cubre el disparador por física; este cubre el
-- faltante por disponible, que es el que consulta el indicador.
create index if not exists ix_tbl_inventario__disponible_bajo_minimo
  on wms.tbl_inventario (almacen_id, producto_id)
  where cantidad_minima > 0 and cantidad_disponible < cantidad_minima;
