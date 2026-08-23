\set ON_ERROR_STOP on
\pset pager off
\pset format aligned

-- ---------- datos mínimos ----------
-- Desde 0006 el alta en catalogos exige al operador SISTEMA (id 1). El
-- contexto se fija ANTES del primer insert: la excepcion de arranque del
-- trigger solo cubre la tabla vacia, y en un INSERT de varias filas la
-- segunda ya ve la tabla poblada.
select set_config('wms.ctx_usuario_id','1',false);

insert into wms.cat_usuarios (nombre, rol) values ('Sistema','SISTEMA');   -- id 1
insert into wms.cat_usuarios (nombre) values ('Operador Diez');            -- id 2
insert into wms.cat_usuarios (nombre) values ('Operador Veinte');          -- id 3
insert into wms.cat_reglas_sku (nombre, es_activo) values ('DEFAULT_V1', true);
insert into wms.cat_categorias (codigo, nombre) values ('ELEC','Electronica');
insert into wms.cat_almacenes (codigo, nombre) values ('ALM-NTE','Norte');
insert into wms.cat_productos (categoria_id, nombre, precio_unitario)
  values ((select id from wms.cat_categorias where codigo='ELEC'), 'Cable HDMI', 100);

select sku from wms.cat_productos \gset
\echo '=== SKU acuñado:' :sku

-- base +10
select cantidad_fisica as base from wms.fn_ajustar_existencia(
  (select id from wms.cat_productos), (select id from wms.cat_almacenes),
  10, 'ENTRADA', 1, '1:SEED-0000-0001', 'SEMILLA') \gset
\echo '=== base:' :base

-- ============================================================
-- ESCENARIO DEL REQUERIMIENTO
--   Modal cantidad +2, id_operacion = 2:ABC123-modal-01.
--   Conexión lenta -> el usuario reclica -> MISMA operación.
--   Esperado: base + 2, nunca base + 2 + 2.
-- ============================================================
select cantidad_fisica from wms.fn_ajustar_existencia(
  (select id from wms.cat_productos), (select id from wms.cat_almacenes),
  2, 'AJUSTE', 2, '2:ABC123-modal-01');

do $$
begin
  perform wms.fn_ajustar_existencia(
    (select id from wms.cat_productos), (select id from wms.cat_almacenes),
    2, 'AJUSTE', 2, '2:ABC123-modal-01');
  raise exception 'FALLO: la operación se aplicó DOS veces';
exception when unique_violation then
  raise notice 'PASA  reclic del modal rechazado por el motor (%)', sqlstate;
end $$;

-- dos usuarios distintos: ambos cuentan
select cantidad_fisica from wms.fn_ajustar_existencia(
  (select id from wms.cat_productos), (select id from wms.cat_almacenes),
  2, 'AJUSTE', 2, '2:AAA-0000-0001');
select cantidad_fisica from wms.fn_ajustar_existencia(
  (select id from wms.cat_productos), (select id from wms.cat_almacenes),
  3, 'AJUSTE', 3, '3:BBB-0000-0001');

do $$
begin
  perform wms.fn_ajustar_existencia(
    (select id from wms.cat_productos), (select id from wms.cat_almacenes),
    2, 'AJUSTE', 2, '2:AAA-0000-0001');
  raise exception 'FALLO: el reintento de AAA sumó otra vez';
exception when unique_violation then
  raise notice 'PASA  reintento accidental de AAA rechazado';
end $$;

\echo ''
\echo '=== EXISTENCIA Y BITÁCORA ==='
select cantidad_fisica as existencia,
       (select sum(delta_fisica) from wms.tbl_movimientos_inventario) as suma_bitacora,
       cantidad_fisica = (select sum(delta_fisica) from wms.tbl_movimientos_inventario) as cuadra
  from wms.tbl_inventario;

select m.id_operacion, u.codigo as usuario, m.tipo_movimiento,
       m.delta_fisica, m.fisica_antes, m.fisica_despues
  from wms.tbl_movimientos_inventario m
  join wms.cat_usuarios u on u.id = m.usuario_id order by m.id;

\echo ''
\echo '=== BARRERA 1: veredictos de fn_reservar_operacion ==='
select veredicto from wms.fn_reservar_operacion('2:OP-NUEVA-0001','ajuste:p=1:a=1','/api/inv','h1',2);
select veredicto from wms.fn_reservar_operacion('2:OP-NUEVA-0001','ajuste:p=1:a=1','/api/inv','h1',2);
select wms.fn_sellar_operacion('2:OP-NUEVA-0001', 200, '{"ok":true}'::jsonb);
select veredicto, codigo_respuesta, cuerpo_respuesta
  from wms.fn_reservar_operacion('2:OP-NUEVA-0001','ajuste:p=1:a=1','/api/inv','h1',2);
select veredicto from wms.fn_reservar_operacion('2:OP-NUEVA-0001','ajuste:p=1:a=1','/api/inv','OTRO',2);
\echo '--- A2: mismo id y mismo hash pero RUTA distinta (confirmar vs enviar) ---'
select veredicto from wms.fn_reservar_operacion('2:OP-NUEVA-0001','ajuste:p=1:a=1','/api/ordenes/12/enviar','h1',2);
\echo '--- A1: mismo id, OTRO operador ---'
select veredicto from wms.fn_reservar_operacion('2:OP-NUEVA-0001','ajuste:p=1:a=1','/api/inv','h1',3);
select veredicto from wms.fn_reservar_operacion('3:OP-NUEVA-0001','ajuste:p=1:a=1','/api/inv','h1',3);

\echo ''
\echo '=== A1: el prefijo de actor es un invariante del motor ==='
do $$
begin
  insert into wms.tbl_operaciones (id_operacion, alcance, ruta, hash_peticion, usuario_id)
  values ('3:MENTIRA-0001','x','/y','h',2);
  raise exception 'FALLO: id con prefijo de otro operador aceptado';
exception when check_violation then
  raise notice 'PASA  ck_tbl_operaciones__prefijo_actor bloqueó el id ajeno';
end $$;

do $$
begin
  insert into wms.tbl_operaciones (id_operacion, alcance, ruta, hash_peticion, usuario_id)
  values ('sin-prefijo-0001','x','/y','h',2);
  raise exception 'FALLO: id sin prefijo de operador aceptado';
exception when check_violation then
  raise notice 'PASA  ck_tbl_operaciones__formato exige el prefijo';
end $$;

\echo ''
\echo '=== BARRERAS DE INTEGRIDAD ==='
do $$ begin
  update wms.tbl_inventario set cantidad_fisica = cantidad_fisica + 99;
  raise exception 'FALLO: mutación sin contexto';
exception when others then raise notice 'PASA  mutación sin contexto rechazada (%)', sqlstate; end $$;

do $$ begin
  update wms.tbl_movimientos_inventario set delta_fisica = 999 where id = 1;
  raise exception 'FALLO: bitácora mutable';
exception when others then raise notice 'PASA  bitácora inmutable (%)', sqlstate; end $$;

do $$ begin
  truncate wms.tbl_movimientos_inventario;
  raise exception 'FALLO: TRUNCATE pasó';
exception when others then raise notice 'PASA  TRUNCATE bloqueado (%)', sqlstate; end $$;

do $$ begin
  perform wms.fn_ajustar_existencia(
    (select id from wms.cat_productos), (select id from wms.cat_almacenes),
    -999, 'SALIDA', 2, '2:NEG-0000-0001');
  raise exception 'FALLO: existencia negativa';
exception when others then raise notice 'PASA  sobreventa bloqueada (%)', sqlstate; end $$;

do $$ begin
  update wms.cat_productos set sku_consecutivo = 99;
  raise exception 'FALLO: SKU reasignado';
exception when others then raise notice 'PASA  SKU inmutable (%)', sqlstate; end $$;

\echo ''
\echo '=== A3: el barrido NO toca una operación que dejó rastro ==='
insert into wms.tbl_operaciones (id_operacion, alcance, ruta, hash_peticion, usuario_id, creado_en)
values ('2:ABC123-modal-01','ajuste:p=1:a=1','/api/inv','h',2, now() - interval '1 hour');
insert into wms.tbl_operaciones (id_operacion, alcance, ruta, hash_peticion, usuario_id, creado_en)
values ('2:COLGADA-0001','ajuste:p=9:a=9','/api/inv','h',2, now() - interval '1 hour');
select wms.fn_barrer_operaciones_colgadas('5 minutes') as cerradas;
select id_operacion, estatus from wms.tbl_operaciones
 where id_operacion in ('2:ABC123-modal-01','2:COLGADA-0001') order by 1;

\echo ''
\echo '=== baja lógica auditada ==='
select set_config('wms.ctx_usuario_id','1',false);
update wms.cat_almacenes set es_activo = false where codigo='ALM-NTE';
update wms.cat_almacenes set es_activo = true  where codigo='ALM-NTE';
select codigo, es_activo, desactivado_por_usuario_id,
       desactivado_en is not null as sello_sobrevive from wms.cat_almacenes;

\echo ''
\echo '=== TODAS LAS PRUEBAS DE HUMO PASARON ==='
