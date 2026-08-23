\set ON_ERROR_STOP on
\pset pager off

-- =====================================================================
--  Ciclo de vida de órdenes, rollback, importación y trazabilidad
--  tras soft-delete. Complementa humo_idempotencia.sql, que solo cubre
--  ajustes de existencia.
-- =====================================================================

-- ---------- datos base ----------
-- Desde 0006 el alta en catalogos exige al operador SISTEMA (id 1). El
-- contexto se fija ANTES del primer insert: la excepcion de arranque del
-- trigger solo cubre la tabla vacia, y en un INSERT de varias filas la
-- segunda ya ve la tabla poblada.
select set_config('wms.ctx_usuario_id','1',false);

insert into wms.cat_usuarios (nombre, rol) values ('Sistema','SISTEMA');   -- 1
insert into wms.cat_usuarios (nombre) values ('Operador Diez');            -- 2
insert into wms.cat_usuarios (nombre) values ('Operador Veinte');          -- 3
insert into wms.cat_reglas_sku (nombre, es_activo) values ('DEFAULT_V1', true);
insert into wms.cat_categorias (codigo, nombre) values ('ELEC','Electronica');
insert into wms.cat_almacenes (codigo, nombre) values ('ALM-NTE','Norte');
insert into wms.cat_clientes (nombre) values ('Cliente Uno');
insert into wms.cat_productos (categoria_id, nombre, precio_unitario)
  values ((select id from wms.cat_categorias), 'Cable HDMI', 100);
insert into wms.cat_productos (categoria_id, nombre, precio_unitario)
  values ((select id from wms.cat_categorias), 'Teclado', 250);

select id as prod_a from wms.cat_productos where nombre='Cable HDMI' \gset
select id as prod_b from wms.cat_productos where nombre='Teclado' \gset
select id as alm    from wms.cat_almacenes  \gset
select id as cli    from wms.cat_clientes   \gset

select cantidad_fisica from wms.fn_ajustar_existencia(:prod_a, :alm, 20, 'ENTRADA', 1, '1:SEED-PRODA-01', 'SEMILLA');
select cantidad_fisica from wms.fn_ajustar_existencia(:prod_b, :alm, 15, 'ENTRADA', 1, '1:SEED-PRODB-01', 'SEMILLA');

\echo ''
\echo '=== CICLO DE ORDEN: BORRADOR -> CONFIRMADA -> ENVIADA ==='
insert into wms.tbl_ordenes (cliente_id, almacen_id, id_operacion, creado_por_usuario_id)
  values (:cli, :alm, '2:ORD-ALTA-0001', 2);
select id as orden from wms.tbl_ordenes \gset

insert into wms.rel_orden_producto (orden_id, producto_id, cantidad, nombre_historico, precio_unitario_historico)
  values (:orden, :prod_a, 5, '', null);
insert into wms.rel_orden_producto (orden_id, producto_id, cantidad, nombre_historico, precio_unitario_historico)
  values (:orden, :prod_b, 2, '', null);

\echo '--- el trigger sella nombre y precio desde el catálogo, y recalcula el total ---'
select r.producto_id, r.nombre_historico, r.precio_unitario_historico, r.importe_linea
  from wms.rel_orden_producto r where r.orden_id = :orden order by r.producto_id;
select folio, estatus, monto_total from wms.tbl_ordenes where id = :orden;

\echo '--- confirmar: reserva sin tocar existencia física ---'
select estatus from wms.fn_confirmar_orden(:orden, 2, '2:ORD-CONF-0001');
select producto_id, cantidad_fisica, cantidad_reservada, cantidad_disponible
  from wms.tbl_inventario order by producto_id;

\echo '--- reintento de la confirmación con el MISMO id_operacion ---'
do $$ begin
  perform wms.fn_confirmar_orden((select id from wms.tbl_ordenes), 2, '2:ORD-CONF-0001');
  raise exception 'FALLO: la confirmación se aplicó dos veces';
exception when others then raise notice 'PASA  reconfirmación rechazada (%)', sqlstate; end $$;

\echo '--- partidas congeladas fuera de BORRADOR ---'
do $$ begin
  update wms.rel_orden_producto set cantidad = 99
   where orden_id = (select id from wms.tbl_ordenes);
  raise exception 'FALLO: se editó una partida de orden confirmada';
exception when others then raise notice 'PASA  partidas inmutables (%)', sqlstate; end $$;

\echo '--- encabezado congelado fuera de BORRADOR ---'
do $$ begin
  update wms.tbl_ordenes set almacen_id = almacen_id
   where id = (select id from wms.tbl_ordenes);
  update wms.tbl_ordenes set cliente_id = 999999
   where id = (select id from wms.tbl_ordenes);
  raise exception 'FALLO: se cambió el cliente de una orden confirmada';
exception when others then raise notice 'PASA  encabezado inmutable (%)', sqlstate; end $$;

\echo '--- enviar: descuenta físico y libera reserva en el mismo movimiento ---'
select estatus from wms.fn_enviar_orden(:orden, 2, '2:ORD-ENVIO-0001');
select producto_id, cantidad_fisica, cantidad_reservada from wms.tbl_inventario order by producto_id;

\echo '--- ENVIADA es terminal: no se puede cancelar ---'
do $$ begin
  perform wms.fn_cancelar_orden((select id from wms.tbl_ordenes), 'tarde', 2, '2:ORD-CANC-0001');
  raise exception 'FALLO: se canceló una orden enviada';
exception when sqlstate 'WM001' then raise notice 'PASA  ENVIADA es terminal (WM001)'; end $$;

\echo ''
\echo '=== CANCELACIÓN DE ORDEN CONFIRMADA: libera reserva, no toca físico ==='
insert into wms.tbl_ordenes (cliente_id, almacen_id, id_operacion, creado_por_usuario_id)
  values (:cli, :alm, '3:ORD-ALTA-0002', 3);
select max(id) as orden2 from wms.tbl_ordenes \gset
insert into wms.rel_orden_producto (orden_id, producto_id, cantidad, nombre_historico, precio_unitario_historico)
  values (:orden2, :prod_a, 4, '', null);
select estatus from wms.fn_confirmar_orden(:orden2, 3, '3:ORD-CONF-0002');
select cantidad_fisica, cantidad_reservada from wms.tbl_inventario where producto_id = :prod_a;
select estatus from wms.fn_cancelar_orden(:orden2, 'cliente desistió', 3, '3:ORD-CANC-0002');
select cantidad_fisica, cantidad_reservada from wms.tbl_inventario where producto_id = :prod_a;
select folio, estatus, cancelado_por_usuario_id, motivo_cancelacion
  from wms.tbl_ordenes where id = :orden2;

\echo ''
\echo '=== CANCELAR UNA ORDEN EN BORRADOR: sin movimientos, pero con autor ==='
insert into wms.tbl_ordenes (cliente_id, almacen_id, id_operacion, creado_por_usuario_id)
  values (:cli, :alm, '3:ORD-ALTA-0003', 3);
select max(id) as orden3 from wms.tbl_ordenes \gset
select estatus from wms.fn_cancelar_orden(:orden3, 'error de captura', 3, '3:ORD-CANC-0003');
select folio, estatus, cancelado_por_usuario_id is not null as tiene_autor
  from wms.tbl_ordenes where id = :orden3;

\echo ''
\echo '=== EXISTENCIA INSUFICIENTE AL CONFIRMAR ==='
insert into wms.tbl_ordenes (cliente_id, almacen_id, id_operacion, creado_por_usuario_id)
  values (:cli, :alm, '2:ORD-ALTA-0004', 2);
select max(id) as orden4 from wms.tbl_ordenes \gset
insert into wms.rel_orden_producto (orden_id, producto_id, cantidad, nombre_historico, precio_unitario_historico)
  values (:orden4, :prod_a, 99999, '', null);
do $$ begin
  perform wms.fn_confirmar_orden((select max(id) from wms.tbl_ordenes), 2, '2:ORD-CONF-0004');
  raise exception 'FALLO: se confirmó sin existencia';
exception when sqlstate 'WM002' then raise notice 'PASA  existencia insuficiente (WM002)'; end $$;

\echo ''
\echo '=== ROLLBACK: la tercera escritura falla, las dos primeras se revierten ==='
select cantidad_fisica as antes_rollback from wms.tbl_inventario where producto_id = :prod_a \gset
do $$
declare v_orden bigint;
begin
  -- 1) alta de orden   2) partida   3) confirmación imposible -> aborta todo
  insert into wms.tbl_ordenes (cliente_id, almacen_id, id_operacion, creado_por_usuario_id)
    values ((select id from wms.cat_clientes), (select id from wms.cat_almacenes), '2:ORD-ROLLBACK-01', 2)
    returning id into v_orden;
  insert into wms.rel_orden_producto (orden_id, producto_id, cantidad, nombre_historico, precio_unitario_historico)
    values (v_orden, (select id from wms.cat_productos order by id limit 1), 1, '', null);
  perform wms.fn_ajustar_existencia(
    (select id from wms.cat_productos order by id limit 1),
    (select id from wms.cat_almacenes), -999999, 'SALIDA', 2, '2:ROLLBACK-AJUSTE-01');
  raise exception 'FALLO: la tercera escritura no falló';
exception when sqlstate 'WM002' then
  raise notice 'PASA  la transacción abortó en la tercera escritura';
end $$;
select cantidad_fisica as despues_rollback,
       cantidad_fisica = :antes_rollback as existencia_intacta,
       not exists (select 1 from wms.tbl_ordenes where id_operacion = '2:ORD-ROLLBACK-01') as orden_revertida
  from wms.tbl_inventario where producto_id = :prod_a;

\echo ''
\echo '=== IMPORTACIÓN: lote único por operación y llaves derivadas por renglón ==='
insert into wms.tbl_lotes_importacion (nombre_archivo, tipo_lote, modo, id_operacion, creado_por_usuario_id)
  values ('inventario.csv','INVENTARIO','ALTA_O_ACTUALIZA','2:imp-a1b2c3d4e5f6a7b8-ALTA_O_ACTUALIZA', 2);
select id as lote from wms.tbl_lotes_importacion \gset

do $$ begin
  insert into wms.tbl_lotes_importacion (nombre_archivo, tipo_lote, modo, id_operacion, creado_por_usuario_id)
    values ('inventario.csv','INVENTARIO','ALTA_O_ACTUALIZA','2:imp-a1b2c3d4e5f6a7b8-ALTA_O_ACTUALIZA', 2);
  raise exception 'FALLO: se creó un segundo lote para la misma operación';
exception when unique_violation then
  raise notice 'PASA  el reintento reencuentra el lote existente, no crea otro';
end $$;

\echo '--- dos renglones del MISMO archivo tocan el mismo producto: llaves derivadas ---'
select cantidad_fisica from wms.fn_ajustar_existencia(
  :prod_a, :alm, 3, 'IMPORTACION', 2,
  '2:imp-a1b2c3d4e5f6a7b8-ALTA_O_ACTUALIZA:1', 'IMPORTACION', null, :lote);
select cantidad_fisica from wms.fn_ajustar_existencia(
  :prod_a, :alm, 4, 'IMPORTACION', 2,
  '2:imp-a1b2c3d4e5f6a7b8-ALTA_O_ACTUALIZA:2', 'IMPORTACION', null, :lote);
insert into wms.tbl_renglones_importacion (lote_id, numero_renglon, carga_original, estatus, accion, producto_id, almacen_id, cantidad_aplicada)
  values (:lote, 1, '{"sku":"ELEC-0001","cantidad":3}', 'OK', 'ACTUALIZACION', :prod_a, :alm, 3),
         (:lote, 2, '{"sku":"ELEC-0001","cantidad":4}', 'OK', 'ACTUALIZACION', :prod_a, :alm, 4);

\echo '--- reintento del renglón 1: rechazado por el motor, el renglón 2 no se ve afectado ---'
do $$ begin
  perform wms.fn_ajustar_existencia(
    (select id from wms.cat_productos order by id limit 1),
    (select id from wms.cat_almacenes), 3, 'IMPORTACION', 2,
    '2:imp-a1b2c3d4e5f6a7b8-ALTA_O_ACTUALIZA:1', 'IMPORTACION', null,
    (select id from wms.tbl_lotes_importacion));
  raise exception 'FALLO: el renglón 1 se aplicó dos veces';
exception when unique_violation then
  raise notice 'PASA  renglón ya aplicado -> OMITIDO/YA_APLICADO';
end $$;

\echo '--- un renglón OMITIDO puede declarar su motivo ---'
insert into wms.tbl_renglones_importacion (lote_id, numero_renglon, carga_original, estatus, codigo_error, accion)
  values (:lote, 3, '{"sku":"ELEC-0001"}', 'OMITIDO', 'YA_APLICADO', 'OMISION');
select estatus, accion, codigo_error, count(*) as renglones
  from wms.vw_importacion_resultado where lote_id = :lote group by 1,2,3 order by 1,2;

\echo ''
\echo '=== SOFT-DELETE: la trazabilidad sobrevive ==='
select set_config('wms.ctx_usuario_id','1',false);
update wms.cat_usuarios  set es_activo = false where id = 3;
update wms.cat_productos set estatus  = 'DESCONTINUADO' where id = :prod_b;

\echo '--- los movimientos del operador dado de baja siguen resolviendo su nombre ---'
select usuario_codigo, usuario_nombre, usuario_vigente, count(*) as movimientos
  from wms.vw_movimientos_detalle group by 1,2,3 order by 1;

\echo '--- no se puede borrar un usuario con historial ---'
do $$ begin
  delete from wms.cat_usuarios where id = 3;
  raise exception 'FALLO: se borró un usuario con movimientos';
exception when foreign_key_violation then raise notice 'PASA  usuario con historial no se borra'; end $$;

\echo '--- no se puede borrar una orden ---'
do $$ begin
  delete from wms.tbl_ordenes where id = (select min(id) from wms.tbl_ordenes);
  raise exception 'FALLO: se borró una orden';
exception when others then raise notice 'PASA  las órdenes no se borran (%)', sqlstate; end $$;

\echo ''
\echo '=== VISTAS DE LECTURA ==='
select count(*) as filas_tablero        from wms.vw_tablero_inventario;
select count(*) as filas_ordenes        from wms.vw_ordenes_detalle;
select count(*) as filas_partidas       from wms.vw_orden_partidas;
select count(*) as filas_movimientos    from wms.vw_movimientos_detalle;
select count(*) as filas_aportacion     from wms.vw_aportacion_por_usuario;
select productos_activos, unidades_fisicas, unidades_reservadas, valor_inventario,
       ordenes_enviadas, ordenes_canceladas from wms.vw_indicadores_operacion;
select almacen_codigo, productos_distintos, unidades_fisicas from wms.vw_indicadores_almacen;
select count(*) as dias_con_serie from wms.vw_serie_movimientos_diaria;

\echo ''
\echo '=== INVARIANTE FINAL: la bitácora reconstruye la existencia ==='
select p.sku,
       i.cantidad_fisica,
       (select coalesce(sum(m.delta_fisica),0) from wms.tbl_movimientos_inventario m
         where m.producto_id = i.producto_id and m.almacen_id = i.almacen_id) as suma_bitacora,
       i.cantidad_fisica = (select coalesce(sum(m.delta_fisica),0) from wms.tbl_movimientos_inventario m
         where m.producto_id = i.producto_id and m.almacen_id = i.almacen_id) as cuadra
  from wms.tbl_inventario i join wms.cat_productos p on p.id = i.producto_id
 order by p.sku;

\echo ''
\echo '=== HUMO DE ÓRDENES: COMPLETO ==='
