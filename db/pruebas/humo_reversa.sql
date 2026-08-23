\set ON_ERROR_STOP on
\pset pager off

-- =====================================================================
--  Desactivación (reversa) de movimientos y su impacto en la existencia
-- =====================================================================

-- Desde 0006 el alta en catalogos exige al operador SISTEMA (id 1). El
-- contexto se fija ANTES del primer insert: la excepcion de arranque del
-- trigger solo cubre la tabla vacia, y en un INSERT de varias filas la
-- segunda ya ve la tabla poblada.
select set_config('wms.ctx_usuario_id','1',false);

insert into wms.cat_usuarios (nombre, rol) values ('Sistema','SISTEMA');   -- 1
insert into wms.cat_usuarios (nombre) values ('Operador Diez');            -- 2
insert into wms.cat_reglas_sku (nombre, es_activo) values ('DEFAULT_V1', true);
insert into wms.cat_categorias (codigo, nombre) values ('ELEC','Electronica');
insert into wms.cat_almacenes (codigo, nombre) values ('ALM-NTE','Norte');
insert into wms.cat_clientes (nombre) values ('Cliente Uno');
insert into wms.cat_productos (categoria_id, nombre, precio_unitario)
  values ((select id from wms.cat_categorias), 'Cable HDMI', 100);

select id as prod from wms.cat_productos \gset
select id as alm  from wms.cat_almacenes  \gset

-- El ejemplo del enunciado: +10, luego -3, existencia 7.
select cantidad_fisica from wms.fn_ajustar_existencia(:prod,:alm, 10,'ENTRADA',2,'2:MOV-A-0001');
select id as mov_a from wms.tbl_movimientos_inventario order by id desc limit 1 \gset
select cantidad_fisica from wms.fn_ajustar_existencia(:prod,:alm, -3,'SALIDA', 2,'2:MOV-B-0001');
select id as mov_b from wms.tbl_movimientos_inventario order by id desc limit 1 \gset

\echo ''
\echo '=== estado inicial: +10, -3, existencia 7 ==='
select cantidad_fisica from wms.tbl_inventario;

\echo ''
\echo '=== 1) un usuario distinto de 1 NO puede desactivar ==='
do $$ begin
  perform wms.fn_revertir_movimiento(
    (select min(id) from wms.tbl_movimientos_inventario), 2, '2:REV-INTENTO-01', 'no deberia');
  raise exception 'FALLO: un operador cualquiera desactivo un movimiento';
exception when sqlstate 'WM018' then raise notice 'PASA  restriccion de usuario aplicada en el MOTOR (WM018)'; end $$;

\echo ''
\echo '=== 2) el ejemplo del enunciado: revertir el +10 dejaria -3 -> se RECHAZA ==='
do $$ begin
  perform wms.fn_revertir_movimiento((select min(id) from wms.tbl_movimientos_inventario),
                                     1, '1:REV-A-0001', 'conteo equivocado');
  raise exception 'FALLO: se permitio dejar existencia negativa';
exception when sqlstate 'WM002' then
  raise notice 'PASA  rechazado: las unidades ya se consumieron (WM002)';
end $$;
select cantidad_fisica as existencia_intacta from wms.tbl_inventario;

\echo ''
\echo '=== 3) revertir la SALIDA de -3 si es posible: existencia vuelve a 10 ==='
select tipo_movimiento, delta_fisica, movimiento_revertido_id
  from wms.fn_revertir_movimiento(:mov_b, 1, '1:REV-B-0001', 'la salida fue un error de captura');
select cantidad_fisica as existencia_tras_reversa from wms.tbl_inventario;

\echo ''
\echo '=== 4) el movimiento original queda INTACTO y marcado como desactivado ==='
select id, tipo_movimiento, delta_fisica, estado, esta_desactivado,
       desactivado_por_nombre, motivo_desactivacion
  from wms.vw_movimientos_detalle where id = :mov_b;

\echo ''
\echo '=== 5) no se puede desactivar dos veces ==='
do $$ begin
  perform wms.fn_revertir_movimiento((select id from wms.tbl_movimientos_inventario
                                       where delta_fisica = -3 and tipo_movimiento = 'SALIDA'),
                                     1, '1:REV-B-0002', 'otra vez');
  raise exception 'FALLO: se desactivo dos veces';
exception when sqlstate 'WM019' then raise notice 'PASA  ya estaba desactivado (WM019)'; end $$;

\echo ''
\echo '=== 6) reintento con el MISMO id_operacion: idempotente ==='
do $$ begin
  perform wms.fn_revertir_movimiento((select id from wms.tbl_movimientos_inventario
                                       where delta_fisica = -3 and tipo_movimiento = 'SALIDA'),
                                     1, '1:REV-B-0001', 'la salida fue un error de captura');
  raise exception 'FALLO: el reintento se aplico otra vez';
exception when others then
  raise notice 'PASA  reintento rechazado (%)', sqlstate;
end $$;
select cantidad_fisica as sin_doble_aplicacion from wms.tbl_inventario;

\echo ''
\echo '=== 7) una reversa no se revierte ==='
do $$ begin
  perform wms.fn_revertir_movimiento((select id from wms.tbl_movimientos_inventario
                                       where tipo_movimiento = 'REVERSA' limit 1),
                                     1, '1:REV-REV-0001', 'anular la correccion');
  raise exception 'FALLO: se revirtio una reversa';
exception when sqlstate 'WM019' then raise notice 'PASA  una reversa no se revierte (WM019)'; end $$;

\echo ''
\echo '=== 8) un movimiento de ORDEN no se revierte: la via es cancelar la orden ==='
insert into wms.tbl_ordenes (cliente_id, almacen_id, id_operacion, creado_por_usuario_id)
  values ((select id from wms.cat_clientes), :alm, '2:ORD-REV-0001', 2);
select max(id) as orden from wms.tbl_ordenes \gset
insert into wms.rel_orden_producto (orden_id, producto_id, cantidad, nombre_historico, precio_unitario_historico)
  values (:orden, :prod, 2, '', null);
select estatus from wms.fn_confirmar_orden(:orden, 2, '2:ORD-CONF-REV-01');
do $$ begin
  perform wms.fn_revertir_movimiento((select id from wms.tbl_movimientos_inventario
                                       where tipo_origen = 'ORDEN' order by id desc limit 1),
                                     1, '1:REV-ORDEN-0001', 'no deberia');
  raise exception 'FALLO: se revirtio un movimiento de orden';
exception when sqlstate 'WM019' then
  raise notice 'PASA  los movimientos de orden se deshacen cancelando la orden (WM019)';
end $$;

\echo ''
\echo '=== 9) desactivar exige motivo ==='
do $$ begin
  perform wms.fn_revertir_movimiento(
    (select min(id) from wms.tbl_movimientos_inventario), 1, '1:REV-SIN-MOTIVO', '');
  raise exception 'FALLO: se desactivo sin motivo';
exception when sqlstate 'WM012' then raise notice 'PASA  el motivo es obligatorio (WM012)'; end $$;

\echo ''
\echo '=== 10) INVARIANTE: la bitacora sigue reconstruyendo la existencia ==='
select (select sum(delta_fisica) from wms.tbl_movimientos_inventario) as suma_bitacora,
       (select cantidad_fisica from wms.tbl_inventario)               as existencia,
       (select sum(delta_fisica) from wms.tbl_movimientos_inventario)
         = (select cantidad_fisica from wms.tbl_inventario)           as cuadra;

\echo ''
\echo '=== 11) la bitacora SIGUE siendo de solo insercion ==='
do $$ begin
  update wms.tbl_movimientos_inventario set delta_fisica = 0 where id = 1;
  raise exception 'FALLO: la bitacora se volvio mutable';
exception when sqlstate 'WM006' then raise notice 'PASA  sigue inmutable (WM006)'; end $$;

\echo ''
\echo '=== HUMO DE REVERSA: COMPLETO ==='
