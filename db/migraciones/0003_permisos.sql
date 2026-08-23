-- =====================================================================
--  Mini WMS + Órdenes  ·  0003 · Privilegios, sesión y tareas programadas
-- ---------------------------------------------------------------------
--  Sin este archivo, la garantía "la suma de la bitácora reconstruye la
--  existencia" es falsa: el rol que la API necesita para operar es el mismo
--  que le permitiría falsificar la bitácora con un INSERT directo. El
--  trigger de inmutabilidad solo cubre UPDATE, DELETE y TRUNCATE.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. Rol de la aplicación
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'wms_api') then
     create role wms_api login password 'cambiar_en_despliegue';
  end if;
end $$;

revoke all on schema wms from public;
grant usage on schema wms to wms_api;

-- Lectura de todo, escritura de lo que corresponde.
grant select on all tables in schema wms to wms_api;
grant insert, update on
      wms.cat_usuarios, wms.cat_categorias, wms.cat_almacenes, wms.cat_clientes,
      wms.cat_productos, wms.cat_reglas_sku, wms.tbl_inventario, wms.tbl_ordenes,
      wms.rel_orden_producto, wms.tbl_operaciones,
      wms.tbl_lotes_importacion, wms.tbl_renglones_importacion
   to wms_api;
grant delete on wms.rel_orden_producto to wms_api;   -- partidas de una orden en BORRADOR
grant usage on all sequences in schema wms to wms_api;

-- ---------------------------------------------------------------------
--  2. La bitácora es de solo lectura para la aplicación
-- ---------------------------------------------------------------------
-- Solo el trigger puede escribirla, y lo hace con los privilegios de su
-- dueño. Así, el privilegio que la API necesita para mutar existencias deja
-- de ser el mismo que le permitiría falsificar el historial.
alter function wms.fn_registrar_movimiento_inventario()
  security definer set search_path = pg_catalog, wms;

revoke insert, update, delete, truncate on wms.tbl_movimientos_inventario from public;
revoke insert, update, delete, truncate on wms.tbl_movimientos_inventario from wms_api;
grant  select on wms.tbl_movimientos_inventario to wms_api;

comment on table wms.tbl_movimientos_inventario is
  'Bitácora append-only. Ningún rol de aplicación tiene INSERT: el único escritor es fn_registrar_movimiento_inventario (SECURITY DEFINER), disparado por toda mutación de tbl_inventario. Garantiza que sum(delta_fisica) reconstruya cantidad_fisica.';

-- ---------------------------------------------------------------------
--  3. Higiene de sesión
-- ---------------------------------------------------------------------
-- Ninguna transacción huérfana debe retener locks sobre tbl_inventario.
alter role wms_api set statement_timeout = '5s';
alter role wms_api set idle_in_transaction_session_timeout = '15s';
alter role wms_api set lock_timeout = '3s';

-- ---------------------------------------------------------------------
--  4. Barrido de operaciones colgadas
-- ---------------------------------------------------------------------
-- Recupera el id_operacion de un proceso que murió entre la reserva y el
-- trabajo. Sin esto, ese id queda inutilizable hasta su expiración y el
-- usuario no puede reintentar.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
     execute 'create extension if not exists pg_cron';
     perform cron.schedule(
       'wms_barrer_operaciones', '* * * * *',
       'select wms.fn_barrer_operaciones_colgadas()');
  else
     raise notice 'pg_cron no disponible: programar wms.fn_barrer_operaciones_colgadas() externamente (cada minuto)';
  end if;
end $$;
